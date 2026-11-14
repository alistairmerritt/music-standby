import Foundation
import Network
import os

/// Pairs the companion with Music as a remote, as the iTunes Remote app's
/// "Connect Manually" does. The companion advertises `_touch-remote._tcp`;
/// Music lists it under Devices in its sidebar; the person clicks it and types
/// `code`; Music then calls `/pair` here, and gets this remote's GUID back.
///
/// Music sends a hash of the typed code with the request. It isn't checked:
/// Music only calls once someone has chosen this remote in its own window,
/// and the GUID handed back lets that same Music, and nothing else, be read.
public final class MusicRemotePairer: Sendable {
    public let code: String
    public let name: String
    private let guid: String
    private let state = OSAllocatedUnfairLock<(listener: NWListener?, waiting: CheckedContinuation<MusicRemotePairing, any Error>?)>(
        initialState: (nil, nil))

    public init(name: String = "Second Chair") {
        self.name = name
        code = String(format: "%04d", Int.random(in: 0...9999))
        guid = (0..<8).map { _ in String(format: "%02X", UInt8.random(in: 0...255)) }.joined()
    }

    public enum Failure: Error, Equatable { case cancelled, couldNotListen(String) }

    /// Advertises until Music pairs or `cancel()`.
    public func pair() async throws -> MusicRemotePairing {
        let listener: NWListener
        do {
            listener = try NWListener(using: .tcp)
        } catch {
            throw Failure.couldNotListen("\(error)")
        }
        let txt = NWTXTRecord(["DvNm": name, "RemV": "10000", "DvTy": "iPhone", "RemN": "Remote", "txtvers": "1", "Pair": guid])
        listener.service = NWListener.Service(name: guid, type: "_touch-remote._tcp", domain: nil, txtRecord: txt)
        let queue = DispatchQueue(label: "MusicRemotePairer")
        listener.newConnectionHandler = { [weak self] connection in
            guard let pairer = self else { connection.cancel(); return }
            pairer.answer(connection, on: queue)
        }
        listener.stateUpdateHandler = { [weak self] newState in
            if case .failed(let error) = newState { self?.finish(.failure(Failure.couldNotListen("\(error)"))) }
        }
        return try await withCheckedThrowingContinuation { continuation in
            state.withLock { $0 = (listener, continuation) }
            listener.start(queue: queue)
        }
    }

    public func cancel() { finish(.failure(Failure.cancelled)) }

    /// One request from Music: `/pair` gets the GUID and ends pairing; anything else a 404.
    private func answer(_ connection: NWConnection, on queue: DispatchQueue) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            guard let serviceName = Self.serviceName(inPairRequest: request) else {
                connection.send(content: Self.http(status: "404 Not Found", body: Data()), completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            // Pairing counts only once the reply has gone out whole. A caller that
            // quits straight away (msbctl) otherwise cut it short, and Music 1.7
            // crashed twice right after such a pairing (12 Nov 2026, "pointer
            // being freed was not allocated" on its main thread).
            let reply = Self.http(status: "200 OK", body: Self.pairResponse(guid: self.guid, name: self.name))
            connection.send(content: reply, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { error in
                if let error {
                    connection.cancel()
                    self.finish(.failure(Failure.couldNotListen("reply to Music failed: \(error)")))
                    return
                }
                // A moment for Music to read it before the connection goes.
                queue.asyncAfter(deadline: .now() + 0.5) {
                    connection.cancel()
                    self.finish(.success(MusicRemotePairing(guid: self.guid, serviceName: serviceName)))
                }
            })
        }
    }

    private func finish(_ result: Result<MusicRemotePairing, any Error>) {
        let (listener, waiting) = state.withLock { current -> (NWListener?, CheckedContinuation<MusicRemotePairing, any Error>?) in
            defer { current = (nil, nil) }
            return (current.listener, current.waiting)
        }
        listener?.cancel()
        waiting?.resume(with: result)
    }

    /// Music's DACP service name from `GET /pair?pairingcode=…&servicename=… HTTP/1.1`.
    static func serviceName(inPairRequest request: String) -> String? {
        guard let line = request.split(separator: "\r\n", maxSplits: 1).first ?? request.split(separator: "\n").first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET", let url = URLComponents(string: String(parts[1])), url.path == "/pair" else { return nil }
        return url.queryItems?.first { $0.name == "servicename" }?.value.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// `cmpa`: this remote's GUID (`cmpg`, 8 bytes), name and device type.
    static func pairResponse(guid: String, name: String) -> Data {
        let bytes = stride(from: 0, to: guid.count, by: 2).compactMap { offset -> UInt8? in
            let start = guid.index(guid.startIndex, offsetBy: offset)
            return UInt8(guid[start..<guid.index(start, offsetBy: 2)], radix: 16)
        }
        return DMAPNode.encode("cmpa", children: [
            DMAPNode.encode("cmpg", Data(bytes)), DMAPNode.encode("cmnm", string: name), DMAPNode.encode("cmty", string: "iPhone"),
        ])
    }

    static func http(status: String, body: Data) -> Data {
        Data("HTTP/1.1 \(status)\r\nContent-Type: application/x-dmap-tagged\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
    }
}

/// The pairing, in the Keychain beside the relay credential.
public struct MusicRemotePairingStore: Sendable {
    public let service: String
    public let account: String

    public init(service: String = "com.alistairmerritt.MusicStandBy.music-remote", account: String = "pairing") {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func load() -> MusicRemotePairing? {
        var result: AnyObject?
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(MusicRemotePairing.self, from: data)
    }

    public func save(_ pairing: MusicRemotePairing) throws {
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = try JSONEncoder().encode(pairing)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    public func delete() { SecItemDelete(query as CFDictionary) }
}

/// The menu's view of the pairing.
@MainActor
@Observable
public final class MusicRemoteAccount {
    public enum State: Equatable, Sendable {
        case unpaired
        case pairing(code: String)
        case paired
        /// Music answered 503: Forget All Remotes was used there.
        case forgottenByMusic
        case failed(String)
    }

    public private(set) var state: State
    public private(set) var client: MusicRemoteClient?
    @ObservationIgnored public var onClientChange: ((MusicRemoteClient?) -> Void)?
    @ObservationIgnored private let store: MusicRemotePairingStore
    @ObservationIgnored private var pairer: MusicRemotePairer?

    public init(store: MusicRemotePairingStore = MusicRemotePairingStore()) {
        self.store = store
        if let pairing = store.load() {
            client = MusicRemoteClient(pairing: pairing)
            state = .paired
        } else {
            state = .unpaired
        }
    }

    public func startPairing() {
        let pairer = MusicRemotePairer()
        self.pairer = pairer
        state = .pairing(code: pairer.code)
        Task {
            do {
                let pairing = try await pairer.pair()
                try store.save(pairing)
                let client = MusicRemoteClient(pairing: pairing)
                self.client = client
                state = .paired
                onClientChange?(client)
            } catch MusicRemotePairer.Failure.cancelled {
                state = client == nil ? .unpaired : .paired
            } catch {
                Logger(subsystem: "com.alistairmerritt.MusicStandBy.Mac", category: "music-remote")
                    .error("pairing with Music failed: \(String(describing: error), privacy: .public)")
                state = .failed("Couldn’t connect to Music. Try again.")
            }
            self.pairer = nil
        }
    }

    public func cancelPairing() { pairer?.cancel() }

    /// Asks the client how its last read went, so the menu can say when Music
    /// has forgotten the pairing.
    public func checkStatus() async {
        guard let client, state == .paired || state == .forgottenByMusic else { return }
        state = await client.status == .unpaired ? .forgottenByMusic : .paired
    }

    /// Forgets the pairing here. Music keeps its side until Settings › Advanced › Forget All Remotes.
    public func forget() {
        store.delete()
        client = nil
        state = .unpaired
        onClientChange?(nil)
    }
}
