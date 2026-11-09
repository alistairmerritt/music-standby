import Foundation

/// A machine-readable error code. An open set: decoders keep codes they don't
/// know, so a newer peer can add one without breaking an older one.
public struct ErrorCode: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
    public var description: String { rawValue }

    // Music.app, reported by the Mac.
    public static let musicNotRunning: ErrorCode = "music_not_running"
    public static let automationDenied: ErrorCode = "automation_denied"
    public static let noCurrentTrack: ErrorCode = "no_current_track"
    public static let commandFailed: ErrorCode = "command_failed"
    public static let commandExpired: ErrorCode = "command_expired"
    public static let unsupportedCommand: ErrorCode = "unsupported_command"
    public static let artworkUnavailable: ErrorCode = "artwork_unavailable"

    // Transport and relay.
    public static let notConnected: ErrorCode = "not_connected"
    public static let macUnreachable: ErrorCode = "mac_unreachable"
    public static let pairingRejected: ErrorCode = "pairing_rejected"
    public static let pairingRevoked: ErrorCode = "pairing_revoked"
    public static let unsupportedProtocolVersion: ErrorCode = "unsupported_protocol_version"
    public static let invalidFrame: ErrorCode = "invalid_frame"
    public static let rateLimited: ErrorCode = "rate_limited"
    public static let `internal`: ErrorCode = "internal"
}

/// An error that crosses the wire: in a `CommandAck`, an `error` frame, an HTTP
/// error body, or a failed `ConnectionStatus`.
public struct ProtocolError: Error, Codable, Equatable, Sendable {
    public var code: ErrorCode
    /// For logs and diagnostics, in English. Not localised, not for display.
    public var message: String?
    /// Seconds to wait before retrying, when the sender knows.
    public var retryAfter: TimeInterval?

    public init(_ code: ErrorCode, message: String? = nil, retryAfter: TimeInterval? = nil) {
        self.code = code
        self.message = message
        self.retryAfter = retryAfter
    }
}

/// The state of one side's link to the relay (or, before a relay exists, to
/// the other device). Shown in the Mac menu and the iPhone app.
public struct ConnectionStatus: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable, CaseIterable {
        case disconnected
        case connecting
        case connected
        /// Lost the link and backing off before the next attempt.
        case reconnecting
        /// Gave up until something changes, e.g. the pairing was revoked.
        case failed
    }

    public var phase: Phase
    /// The device on the far side, once known.
    public var peerName: String?
    public var since: Date?
    public var nextAttemptAt: Date?
    public var error: ProtocolError?

    public init(phase: Phase, peerName: String? = nil, since: Date? = nil, nextAttemptAt: Date? = nil, error: ProtocolError? = nil) {
        self.phase = phase
        self.peerName = peerName
        self.since = since
        self.nextAttemptAt = nextAttemptAt
        self.error = error
    }

    public static let disconnected = ConnectionStatus(phase: .disconnected)
    public static let connecting = ConnectionStatus(phase: .connecting)
    public static func connected(to peerName: String, since: Date? = nil) -> ConnectionStatus {
        ConnectionStatus(phase: .connected, peerName: peerName, since: since)
    }
    public static func reconnecting(at date: Date, after error: ProtocolError? = nil) -> ConnectionStatus {
        ConnectionStatus(phase: .reconnecting, nextAttemptAt: date, error: error)
    }
    public static func failed(_ error: ProtocolError) -> ConnectionStatus {
        ConnectionStatus(phase: .failed, error: error)
    }
}
