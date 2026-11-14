import Foundation
import StandByProtocol

/// The relay's HTTPS endpoints the Mac uses (docs/relay/API-v1.md §3).
public struct RelayClient: Sendable {
    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public var host: String { baseURL.host() ?? baseURL.absoluteString }

    /// `ws`/`wss` for `http`/`https`.
    public var socketURL: URL {
        var components = URLComponents(url: baseURL.appending(path: "v1/mac/socket"), resolvingAgainstBaseURL: false)!
        components.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        return components.url!
    }

    /// `POST /v1/pairings`, once per Mac.
    public func createPairing(device: DeviceIdentity) async throws -> PairingCreateResponse {
        try await call("POST", "v1/pairings", body: PairingCreateRequest(device: device), expect: 201)
    }

    /// `POST /v1/pairing/code`: a fresh six-digit code; any earlier one dies.
    public func newPairingCode(macToken: String) async throws -> PairingCodeResponse {
        try await call("POST", "v1/pairing/code", token: macToken, body: Optional<String>.none, expect: 201)
    }

    /// `DELETE /v1/pairing`: revokes the Mac's and the phone's credentials.
    public func unpair(macToken: String) async throws {
        let _: Empty = try await call("DELETE", "v1/pairing", token: macToken, body: Optional<String>.none, expect: 204)
    }

    /// `PUT /v1/artwork/{artworkID}`.
    public func uploadArtwork(_ image: Data, descriptor: ArtworkDescriptor, macToken: String) async throws -> ArtworkDescriptor {
        var request = URLRequest(url: baseURL.appending(path: "v1/artwork/\(descriptor.artworkID)"))
        request.httpMethod = "PUT"
        request.setValue("Bearer \(macToken)", forHTTPHeaderField: "Authorization")
        request.setValue(descriptor.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = image
        return try await perform(request, expect: 201)
    }

    // MARK: Plumbing

    private struct Empty: Decodable {}

    private func call<Body: Encodable, Result: Decodable>(_ method: String, _ path: String, token: String? = nil, body: Body?, expect: Int) async throws -> Result {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try StandByWire.makeEncoder().encode(body)
        }
        return try await perform(request, expect: expect)
    }

    private func perform<Result: Decodable>(_ request: URLRequest, expect: Int) async throws -> Result {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == expect else {
            if let failure = try? StandByWire.makeDecoder().decode(ErrorResponse.self, from: data) { throw failure.error }
            throw ProtocolError(.internal, message: "HTTP \(status) from \(request.url?.path() ?? "relay")")
        }
        if Result.self == Empty.self { return Empty() as! Result }
        return try StandByWire.makeDecoder().decode(Result.self, from: data)
    }
}
