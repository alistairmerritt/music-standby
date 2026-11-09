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
    func send(_ command: RemoteCommand) async throws -> CommandAck
}

/// Authenticated HTTPS calls to the relay. Plain data and no process state, so
/// the extension can use it while the main app is suspended or gone.
public struct RelayClient: CommandSender, Sendable {
    /// Apple documents no time budget for a command handler. The relay proposal
    /// chose 1.5 s, just past its own 1.2 s wait for the Mac. Unmeasured.
    public static let commandTimeout: TimeInterval = 1.5
    public static let defaultTimeout: TimeInterval = 10

    public let configuration: RelayConfiguration
    private let http: any HTTPSending
    private let token: @Sendable () -> String?
    private let artworkPolicy: ArtworkPolicy

    public init(configuration: RelayConfiguration, http: any HTTPSending, artworkPolicy: ArtworkPolicy = ArtworkPolicy(), token: @escaping @Sendable () -> String?) {
        self.configuration = configuration
        self.http = http
        self.artworkPolicy = artworkPolicy
        self.token = token
    }

    // MARK: Endpoints

    /// Trades a six-digit code for a phone token. Needs no authorisation.
    public func claimPairing(code: PairingCode, device: DeviceIdentity) async throws -> PairingGrant {
        var request = try makeRequest(RelayPath.claimPairing, method: "POST", authenticated: false)
        try attach(PairingClaim(code: code.value, device: device), to: &request)
        do {
            return try decode(PairingGrant.self, from: try await perform(request).0)
        } catch TransportError.httpStatus(404), TransportError.commandRejected {
            throw TransportError.pairingRejected
        }
    }

    public func send(_ command: RemoteCommand) async throws -> CommandAck {
        var request = try makeRequest(RelayPath.commands, method: "POST", timeout: Self.commandTimeout)
        request.setValue(command.id.uuidString, forHTTPHeaderField: "Idempotency-Key")
        try attach(CommandRequest(command: command), to: &request)
        let response: CommandResponse
        do {
            response = try decode(CommandResponse.self, from: try await perform(request).0)
        } catch TransportError.timedOut {
            throw TransportError.macUnreachable
        }
        guard response.ack.commandID == command.id else { throw TransportError.malformedResponse }
        return response.ack
    }

    public func registerStartToken(_ hex: String) async throws {
        var request = try makeRequest(RelayPath.startToken, method: "POST")
        try attach(StartTokenRegistration(pushToStartToken: hex), to: &request)
        _ = try await perform(request)
    }

    public func registerSessionToken(_ hex: String, sessionID: String) async throws {
        var request = try makeRequest(RelayPath.sessionToken, method: "POST")
        try attach(SessionTokenRegistration(sessionID: sessionID, pushToken: hex), to: &request)
        _ = try await perform(request)
    }

    public func invalidateSessionToken(sessionID: String) async throws {
        _ = try await perform(try makeRequest(RelayPath.sessionToken(id: sessionID), method: "DELETE"))
    }

    /// The authoritative state, or nil when the relay holds no session.
    public func fetchSession() async throws -> RelaySession? {
        let (data, response) = try await perform(try makeRequest(RelayPath.session, method: "GET"))
        if response.statusCode == 204 { return nil }
        return try decode(RelaySessionResponse.self, from: data).session
    }

    public func deletePairing() async throws {
        _ = try await perform(try makeRequest(RelayPath.pairing, method: "DELETE"))
    }

    // MARK: Requests

    func makeRequest(_ path: String, method: String, authenticated: Bool = true, timeout: TimeInterval = RelayClient.defaultTimeout) throws -> URLRequest {
        var base = configuration.baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: "\(base)/\(path)") else { throw TransportError.malformedResponse }
        return try makeRequest(url: url, method: method, authenticated: authenticated, timeout: timeout)
    }

    private func makeRequest(url: URL, method: String, authenticated: Bool, timeout: TimeInterval) throws -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue(String(StandByWire.version), forHTTPHeaderField: "X-Protocol-Version")
        if authenticated {
            guard let token = token() else { throw TransportError.notPaired }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
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
        case (401, _), (_, .pairingRevoked?):
            return .pairingRevoked
        case (429, _), (_, .rateLimited?):
            return .rateLimited(retryAfter: detail?.retryAfter ?? response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
        case (504, _), (_, .macUnreachable?):
            return .macUnreachable
        case (_, .pairingRejected?):
            return .pairingRejected
        case (_, let code?):
            return .commandRejected(code)
        default:
            return .httpStatus(response.statusCode)
        }
    }
}

// MARK: - Artwork

extension RelayClient: ArtworkFetching {
    public func fetch(url: URL) async throws -> Data {
        try artworkPolicy.validate(url: url, allowedHost: configuration.host)
        return try await fetchArtwork(try makeRequest(url: url, method: "GET", authenticated: true, timeout: artworkPolicy.timeout))
    }

    public func fetch(id: String) async throws -> Data {
        guard ArtworkID.isValid(id) else { throw TransportError.artworkUnavailable }
        return try await fetchArtwork(try makeRequest(RelayPath.artwork(id: id), method: "GET", timeout: artworkPolicy.timeout))
    }

    private func fetchArtwork(_ source: URLRequest) async throws -> Data {
        var request = source
        request.setValue("\(ArtworkFormat.png.rawValue), \(ArtworkFormat.jpeg.rawValue)", forHTTPHeaderField: "Accept")
        let (data, response) = try await perform(request, maxBytes: artworkPolicy.maximumByteCount)
        try artworkPolicy.validate(data: data, contentType: response.value(forHTTPHeaderField: "Content-Type"))
        return data
    }
}
