import Foundation
import Security

/// The result of pairing. The extension needs it while the phone is locked.
public struct RelayCredential: Codable, Equatable, Sendable {
    public var configuration: RelayConfiguration
    public var pairingID: String
    public var token: String
    public var mac: PairedMac

    public init(configuration: RelayConfiguration, pairingID: String, token: String, mac: PairedMac) {
        self.configuration = configuration
        self.pairingID = pairingID
        self.token = token
        self.mac = mac
    }
}

public protocol CredentialStore: Sendable {
    func load() throws -> RelayCredential?
    func save(_ credential: RelayCredential) throws
    func delete() throws
}

public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var credential: RelayCredential?

    public init(_ credential: RelayCredential? = nil) {
        self.credential = credential
    }

    public func load() -> RelayCredential? { lock.withLock { credential } }
    public func save(_ credential: RelayCredential) { lock.withLock { self.credential = credential } }
    public func delete() { lock.withLock { credential = nil } }
}

public enum CredentialStoreError: Error, Equatable, Sendable {
    case keychain(OSStatus)
}

/// The phone's relay credential in the Keychain.
///
/// Readable after first unlock, so a docked locked phone can still send commands,
/// and never restored to another device. No access group is named: both targets
/// list the same `keychain-access-groups` entry first, and new items go there.
public struct KeychainCredentialStore: CredentialStore {
    private let service: String
    private let account: String

    public init(service: String = "com.alistairmerritt.MusicStandBy.relay", account: String = "phone-credential") {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    public func load() throws -> RelayCredential? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw CredentialStoreError.keychain(status) }
        return try JSONDecoder().decode(RelayCredential.self, from: data)
    }

    public func save(_ credential: RelayCredential) throws {
        let data = try JSONEncoder().encode(credential)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw CredentialStoreError.keychain(status) }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw CredentialStoreError.keychain(added) }
    }

    public func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialStoreError.keychain(status) }
    }
}
