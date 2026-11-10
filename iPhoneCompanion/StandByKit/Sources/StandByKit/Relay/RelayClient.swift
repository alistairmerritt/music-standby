import Foundation

/// The HTTP seam, so requests can be tested without a network.
public protocol HTTPSending: Sendable {
    /// `maxBytes` stops reading a response that grows past it.
    func send(_ request: URLRequest, maxBytes: Int?) async throws -> (Data, HTTPURLResponse)
}

/// Never follows a redirect, so a bearer token can't be carried to another host.
private final class RedirectRefusal: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}

public struct URLSessionHTTP: HTTPSending {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest, maxBytes: Int?) async throws -> (Data, HTTPURLResponse) {
        let delegate = RedirectRefusal()
        guard let maxBytes else {
            let (data, response) = try await session.data(for: request, delegate: delegate)
            guard let http = response as? HTTPURLResponse else { throw TransportError.malformedResponse }
            return (data, http)
        }
        let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
        guard let http = response as? HTTPURLResponse else { throw TransportError.malformedResponse }
        guard http.expectedContentLength <= Int64(maxBytes) else {
            bytes.task.cancel()
            throw TransportError.artworkUnavailable
        }
        var data = Data()
        data.reserveCapacity(max(0, Int(http.expectedContentLength)))
        for try await byte in bytes {
            guard data.count < maxBytes else {
                bytes.task.cancel()
                throw TransportError.artworkUnavailable
            }
            data.append(byte)
        }
        return (data, http)
    }
}

/// Sends a command and waits for the Mac's answer.
public protocol CommandSender: Sendable {
    /// `sessionID` is the Now Playing session the command came from. The relay
    /// refuses a command for any other session.
    func send(_ command: RemoteCommand, sessionID: String) async throws -> CommandAck
}

/// Authenticated HTTPS calls to the relay. Plain data and no process state, so
/// the extension can use it while the main app is suspended or gone.
public struct RelayClient: CommandSender, Sendable {
    /// Apple documents no time budget for a command handler. API-v1 §7 sets
    /// 1.5 s, just past the relay's own 1.2 s wait for the Mac. Unmeasured.
    public static let commandTimeout: TimeInterval = 1.5
    public static let defaultTimeout: TimeInterval = 10

    public let configuration: RelayConfiguration
    /// Needed only for the bearer form of the artwork path.
    public let pairingID: String?
    private let http: any HTTPSending
    private let token: @Sendable () -> String?
    private let artworkPolicy: ArtworkPolicy

    public init(configuration: RelayConfiguration, http: any HTTPSending, artworkPolicy: ArtworkPolicy = ArtworkPolicy(), pairingID: String? = nil, token: @escaping @Sendable () -> String?) {
        self.configuration = configuration
        self.http = http
        self.artworkPolicy = artworkPolicy
        self.pairingID = pairingID
        self.token = token
    }

    // MARK: Pairing

    /// Offers a six-digit code. Grants nothing: the person at the Mac must allow
    /// this phone, which `claimStatus(_:)` reports.
    public func claimPairing(code: PairingCode, device: DeviceIdentity) async throws -> PairingClaimResponse {
        var request = try makeRequest(RelayPath.claimPairing, method: "POST", bearer: nil)
        try attach(PairingClaimRequest(code: code.value, phone: device), to: &request)
        do {
            return try decode(PairingClaimResponse.self, from: try await perform(request).0)
        } catch TransportError.httpStatus(404), TransportError.commandRejected {
            // Whatever the relay calls it, a refused code is a refused code.
            throw TransportError.pairingRejected
        }
    }

    /// One poll of a claim, authenticated by its own secret. `approved` carries
    /// the phone token, once.
    public func claimStatus(_ claim: PairingClaimResponse) async throws -> PairingClaimStatus {
        let request = try makeRequest(RelayPath.claimStatus(id: claim.claimID), method: "GET", bearer: claim.claimSecret)
        do {
            return try decode(PairingClaimStatus.self, from: try await perform(request).0)
        } catch TransportError.pairingRevoked, TransportError.httpStatus(410) {
            // An unknown claim secret means the claim is gone.
            throw TransportError.pairingExpired
        }
    }

    // MARK: Session

    public func send(_ command: RemoteCommand, sessionID: String) async throws -> CommandAck {
        var request = try makeRequest(RelayPath.commands, method: "POST", timeout: Self.commandTimeout)
        request.setValue(command.id.uuidString, forHTTPHeaderField: "Idempotency-Key")
        try attach(CommandRequest(command: command, sessionID: sessionID), to: &request)
        let response: CommandResponse
        do {
            response = try decode(CommandResponse.self, from: try await perform(request).0)
        } catch TransportError.timedOut {
            throw TransportError.macUnreachable
        }
        guard response.ack.commandID == command.id else { throw TransportError.malformedResponse }
        return response.ack
    }

    /// What the relay holds now: the session, if any, and the Mac's last state.
    public func fetchSession() async throws -> SessionState {
        try decode(SessionState.self, from: try await perform(try makeRequest(RelayPath.session, method: "GET")).0)
    }

    /// Ends the session at the relay. It then starts no new one for the same
    /// listening session on the Mac (API-v1 §6).
    public func endSession(sessionID: String) async throws {
        var request = try makeRequest(RelayPath.endSession, method: "POST")
        try attach(SessionEndRequest(sessionID: sessionID), to: &request)
        _ = try await perform(request)
    }

    public func deletePairing() async throws {
        _ = try await perform(try makeRequest(RelayPath.pairing, method: "DELETE"))
    }

    // MARK: Push tokens

    public func registerStartToken(_ hex: String) async throws {
        var request = try makeRequest(RelayPath.startToken, method: "PUT")
        try attach(PushToStartTokenRegistration(token: hex), to: &request)
        _ = try await perform(request)
    }

    public func registerSessionToken(_ hex: String, sessionID: String) async throws {
        var request = try makeRequest(RelayPath.sessionToken, method: "PUT")
        try attach(SessionPushTokenRegistration(sessionID: sessionID, token: hex), to: &request)
        _ = try await perform(request)
    }

    public func invalidateSessionToken(sessionID: String) async throws {
        _ = try await perform(try makeRequest(RelayPath.sessionToken(id: sessionID), method: "DELETE"))
    }

    // MARK: Requests

    /// Authenticated with the phone token unless `bearer` says otherwise.
    func makeRequest(_ path: String, method: String, timeout: TimeInterval = RelayClient.defaultTimeout) throws -> URLRequest {
        guard let token = token() else { throw TransportError.notPaired }
        return try makeRequest(path, method: method, bearer: token, timeout: timeout)
    }

    func makeRequest(_ path: String, method: String, bearer: String?, timeout: TimeInterval = RelayClient.defaultTimeout) throws -> URLRequest {
        var base = configuration.baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: "\(base)/\(path)") else { throw TransportError.malformedResponse }
        return makeRequest(url: url, method: method, bearer: bearer, timeout: timeout)
    }

    private func makeRequest(url: URL, method: String, bearer: String?, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue(String(StandByWire.version), forHTTPHeaderField: "X-Protocol-Version")
        if let bearer {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func attach(_ body: some Encodable, to request: inout URLRequest) throws {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try StandByWire.makeEncoder().encode(body)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try StandByWire.makeDecoder().decode(type, from: data)
        } catch {
            throw TransportError.malformedResponse
        }
    }

    private func perform(_ request: URLRequest, maxBytes: Int? = nil) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await http.send(request, maxBytes: maxBytes)
        } catch let error as TransportError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw TransportError.timedOut
        } catch {
            throw TransportError.network(error.localizedDescription)
        }
        if let version = response.value(forHTTPHeaderField: "X-Protocol-Version").flatMap(Int.init), version != StandByWire.version {
            throw TransportError.commandRejected(.unsupportedProtocolVersion)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw Self.error(for: response, body: data)
        }
        return (data, response)
    }

    private static func error(for response: HTTPURLResponse, body: Data) -> TransportError {
        let detail = try? StandByWire.makeDecoder().decode(ErrorResponse.self, from: body).error
        switch (response.statusCode, detail?.code) {
        case (401, _), (_, .unauthorized?), (_, .pairingRevoked?):
            return .pairingRevoked
        case (429, _), (_, .rateLimited?):
            return .rateLimited(retryAfter: detail?.retryAfter ?? response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
        case (504, _), (_, .macUnreachable?):
            return .macUnreachable
        case (_, .pairingRejected?), (_, .pairingCodeInvalid?):
            return .pairingRejected
        case (_, .claimExpired?):
            return .pairingExpired
        case (_, .claimDenied?):
            return .pairingDenied
        case (_, let code?):
            return .commandRejected(code)
        default:
            return .httpStatus(response.statusCode)
        }
    }
}

// MARK: - Artwork

extension RelayClient: ArtworkFetching {
    /// A signed capability URL from the relay. Only its own host is trusted, and
    /// the phone token rides along so an expired signature still works.
    public func fetch(url: URL) async throws -> Data {
        try artworkPolicy.validate(url: url, allowedHost: configuration.host)
        return try await fetchArtwork(makeRequest(url: url, method: "GET", bearer: token(), timeout: artworkPolicy.timeout))
    }

    /// The bearer form, for when there is no signed URL to hand.
    public func fetch(id: String) async throws -> Data {
        guard ArtworkID.isValid(id), let pairingID else { throw TransportError.artworkUnavailable }
        return try await fetchArtwork(try makeRequest(RelayPath.artwork(pairingID: pairingID, artworkID: id), method: "GET", timeout: artworkPolicy.timeout))
    }

    private func fetchArtwork(_ source: URLRequest) async throws -> Data {
        var request = source
        request.setValue("\(ArtworkFormat.png.rawValue), \(ArtworkFormat.jpeg.rawValue)", forHTTPHeaderField: "Accept")
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await perform(request, maxBytes: artworkPolicy.maximumByteCount)
        } catch TransportError.pairingRevoked {
            // A bad signature also answers 401. Missing artwork never ends a pairing.
            throw TransportError.artworkUnavailable
        }
        try artworkPolicy.validate(data: data, contentType: response.value(forHTTPHeaderField: "Content-Type"))
        return data
    }
}
