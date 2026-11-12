import Foundation

// The relay's HTTP surface as the phone uses it: docs/relay/API-v1.md.
// Bodies are the shared types in `StandByProtocol/Relay.swift`.

enum RelayPath {
    static let claimPairing = "v1/pairing/claim"
    static func claimStatus(id: String) -> String { "v1/pairing/claim/\(id.relayPathComponent)" }
    static let commands = "v1/commands"
    static let startToken = "v1/tokens/start"
    static let alertToken = "v1/tokens/alert"
    static let deviceToken = "v1/tokens/device"
    static let handBackStatus = "v1/hand-back/status"
    static let sessionToken = "v1/tokens/session"
    static func sessionToken(id: String) -> String { "v1/tokens/session/\(id.relayPathComponent)" }
    static let session = "v1/session"
    static let endSession = "v1/session/end"
    static let pairing = "v1/pairing"
    /// The bearer form of the artwork path. Pushes carry a signed URL instead.
    static func artwork(pairingID: String, artworkID: String) -> String {
        "v1/artwork/\(pairingID.relayPathComponent)/\(artworkID.relayPathComponent)"
    }
}

private extension String {
    var relayPathComponent: String {
        addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_"))) ?? ""
    }
}

/// Where the relay is. HTTPS only, except loopback for a local development relay.
public struct RelayConfiguration: Codable, Equatable, Sendable {
    public let baseURL: URL

    public init?(baseURL: URL) {
        guard let scheme = baseURL.scheme?.lowercased(), let host = baseURL.host()?.lowercased() else { return nil }
        guard scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)) else { return nil }
        self.baseURL = baseURL
    }

    /// A bare host name, as a build setting supplies it, served over HTTPS.
    public init?(host: String) {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains("$"),
              let url = URL(string: "https://\(trimmed)"), url.host() != nil else { return nil }
        self.init(baseURL: url)
    }

    public var host: String? { baseURL.host() }
}
