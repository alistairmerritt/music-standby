import Foundation
import Observation
import Security
import StandByProtocol

/// What the Mac keeps to talk to its relay.
public struct RelayCredentials: Codable, Equatable, Sendable {
    public var baseURL: URL
    public var pairingID: String
    public var macToken: String

    public init(baseURL: URL, pairingID: String, macToken: String) {
        self.baseURL = baseURL
        self.pairingID = pairingID
        self.macToken = macToken
    }
}

public protocol RelayCredentialStore: Sendable {
    func load() -> RelayCredentials?
    func save(_ credentials: RelayCredentials) throws
    func delete() throws
}

/// The app's store: one generic-password item in the login Keychain.
public struct KeychainCredentialStore: RelayCredentialStore {
    public let service: String
    public let account: String

    public init(service: String = "com.alistairmerritt.MusicStandBy.relay", account: String) {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func load() -> RelayCredentials? {
        var result: AnyObject?
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(RelayCredentials.self, from: data)
    }

    public func save(_ credentials: RelayCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw ProtocolError(.internal, message: "Keychain error \(status)") }
    }

    public func delete() throws {
        SecItemDelete(query as CFDictionary)
    }
}

/// A 0600 JSON file. For `msbctl` and tests, which shouldn't touch the Keychain.
public struct FileCredentialStore: RelayCredentialStore {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func load() -> RelayCredentials? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RelayCredentials.self, from: data)
    }

    public func save(_ credentials: RelayCredentials) throws {
        try JSONEncoder().encode(credentials).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func delete() throws {
        try? FileManager.default.removeItem(at: url)
    }
}

/// The Mac's registration with one relay: creates the pairing on first use,
/// hands out pairing codes, and unpairs. The token goes to `RelayTransport`
/// through `token`, which is safe to call from any thread.
@MainActor
@Observable
public final class RelayAccount {
    public let client: RelayClient
    public private(set) var credentials: RelayCredentials?
    /// The code on screen, while it is valid.
    public private(set) var pairingCode: PairingCodeResponse?
    public private(set) var lastError: String?

    @ObservationIgnored private let store: RelayCredentialStore
    @ObservationIgnored private let tokenBox: TokenBox

    public init(baseURL: URL, store: RelayCredentialStore) {
        client = RelayClient(baseURL: baseURL)
        self.store = store
        let saved = store.load().flatMap { $0.baseURL == baseURL ? $0 : nil }
        credentials = saved
        tokenBox = TokenBox(saved?.macToken)
    }

    /// For the transport. Reads a lock-protected copy, not the Keychain.
    public nonisolated var token: @Sendable () -> String? {
        let box = tokenBox
        return { box.value }
    }

    public var isRegistered: Bool { credentials != nil }

    /// Creates the pairing once. Safe to call on every launch.
    public func register(device: DeviceIdentity) async {
        guard credentials == nil else { return }
        do {
            let created = try await client.createPairing(device: device)
            let saved = RelayCredentials(baseURL: client.baseURL, pairingID: created.pairingID, macToken: created.macToken)
            try store.save(saved)
            credentials = saved
            tokenBox.value = saved.macToken
            lastError = nil
        } catch {
            lastError = "Couldn’t register with the relay: \(error.localizedDescription)"
        }
    }

    public func requestPairingCode() async {
        guard let credentials else { return }
        do {
            pairingCode = try await client.newPairingCode(macToken: credentials.macToken)
            lastError = nil
        } catch {
            lastError = "Couldn’t get a pairing code: \(error.localizedDescription)"
        }
    }

    public func clearPairingCode() {
        pairingCode = nil
    }

    /// Revokes both sides' credentials. The Mac registers afresh next time.
    public func unpair() async {
        guard let credentials else { return }
        do {
            try await client.unpair(macToken: credentials.macToken)
        } catch {
            lastError = "The relay didn’t confirm unpairing: \(error.localizedDescription)"
        }
        try? store.delete()
        self.credentials = nil
        tokenBox.value = nil
        pairingCode = nil
    }
}

/// A lock-protected token so the transport can read it off the main actor.
final class TokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: String?
    init(_ value: String?) { _value = value }
    var value: String? {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

extension ProtocolError: @retroactive LocalizedError {
    public var errorDescription: String? {
        message.map { "\(code): \($0)" } ?? code.rawValue
    }
}
