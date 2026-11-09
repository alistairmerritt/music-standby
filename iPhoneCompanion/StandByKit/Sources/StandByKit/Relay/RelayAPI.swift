import Foundation

// The relay's HTTP surface as the iOS app understands it.
//
// DRAFT. `Shared/StandByProtocol` fixes the messages but deliberately leaves the
// pairing, token and session endpoints out of version 1. Everything in this file
// comes from `docs/ios/RELAY-DESIGN-8-NOV-2026.md`, a proposal, and is collected
// here so the agreed contract changes one file. See `docs/ios/RELAY-CLIENT-CONTRACT.md`.

enum RelayPath {
    static let claimPairing = "v1/pair/claim"
    static let commands = "v1/commands"
    static let startToken = "v1/tokens/start"
    static let sessionToken = "v1/tokens/session"
    static let session = "v1/session"
    static let pairing = "v1/pairing"
    static func sessionToken(id: String) -> String { "v1/tokens/session/\(id.relayPathComponent)" }
    static func artwork(id: String) -> String { "v1/artwork/\(id.relayPathComponent)" }
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

    public var host: String? { baseURL.host() }
}

/// Body of `POST /v1/pair/claim`.
public struct PairingClaim: Codable, Equatable, Sendable {
    public var code: String
    /// The relay proposal's field.
    public var deviceName: String
    /// What the shared protocol's `paired` frame needs to tell the Mac.
    public var device: DeviceIdentity

    public init(code: String, device: DeviceIdentity) {
        self.code = code
        deviceName = device.name
        self.device = device
    }
}

/// `200` body of `POST /v1/pair/claim`.
public struct PairingGrant: Codable, Equatable, Sendable {
    public var pairingID: String
    public var phoneToken: String
    public var mac: PairedMac

    public init(pairingID: String, phoneToken: String, mac: PairedMac) {
        self.pairingID = pairingID
        self.phoneToken = phoneToken
        self.mac = mac
    }
}

/// Body of `POST /v1/tokens/start`.
public struct StartTokenRegistration: Codable, Equatable, Sendable {
    public var pushToStartToken: String
}

/// Body of `POST /v1/tokens/session`.
public struct SessionTokenRegistration: Codable, Equatable, Sendable {
    public var sessionID: String
    public var pushToken: String
}

/// The session the relay currently holds.
public struct RelaySession: Codable, Equatable, Sendable {
    /// The Now Playing session identifier. The relay owns it.
    public var sessionID: String
    public var playback: PlaybackMessage

    public init(sessionID: String, playback: PlaybackMessage) {
        self.sessionID = sessionID
        self.playback = playback
    }
}

/// `200` body of `GET /v1/session`.
public struct RelaySessionResponse: Codable, Equatable, Sendable {
    public var session: RelaySession?

    public init(session: RelaySession?) {
        self.session = session
    }
}
