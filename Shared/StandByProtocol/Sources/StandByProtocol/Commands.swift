import Foundation

/// The controls the iPhone offers.
///
/// `play`, `pause`, `next` and `previous` are the four from the temporary
/// contract. `seek`, `setVolume` and `selectOutput` were added on 11 November
/// 2026, each with one value on `RemoteCommand`. Adding a case is safe for
/// the Mac, which has rejected an unknown kind by id (`unsupported_command`)
/// since version 1, and for the relay, which passes `kind` through as text.
public enum CommandKind: String, Codable, Sendable, CaseIterable {
    case play, pause, next, previous
    /// Jump to `RemoteCommand.position` seconds into the current track.
    case seek
    /// Set Music's own output volume to `RemoteCommand.level`, 0 to 1.
    case setVolume
    /// Play to the `AudioOutput` whose id is `RemoteCommand.outputID`, and only to it.
    case selectOutput

    /// The field a command of this kind must carry, if any.
    public var requiredValue: String? {
        switch self {
        case .play, .pause, .next, .previous: nil
        case .seek: "position"
        case .setVolume: "level"
        case .selectOutput: "outputID"
        }
    }
}

/// A playback command from the phone, forwarded to the Mac by the relay.
public struct RemoteCommand: Codable, Equatable, Sendable, Identifiable {
    /// Also the relay's idempotency key. A repeated id must not act twice.
    public var id: UUID
    public var kind: CommandKind
    /// When the phone issued it. The Mac refuses commands older than
    /// `maximumAge`: a pause that arrives a minute late is worse than none.
    public var issuedAt: Date?
    /// Seconds into the track, for `seek`. The Mac clamps it to the track.
    public var position: TimeInterval?
    /// Music's output volume, 0 to 1, for `setVolume`. The Mac clamps it.
    public var level: Double?
    /// `AudioOutput.id`, for `selectOutput`.
    public var outputID: String?

    public static let maximumAge: TimeInterval = 10

    public init(id: UUID = UUID(), kind: CommandKind, issuedAt: Date? = nil,
                position: TimeInterval? = nil, level: Double? = nil, outputID: String? = nil) {
        self.id = id
        self.kind = kind
        self.issuedAt = issuedAt
        self.position = position
        self.level = level
        self.outputID = outputID
    }

    public static func seek(to position: TimeInterval, id: UUID = UUID(), issuedAt: Date? = nil) -> RemoteCommand {
        RemoteCommand(id: id, kind: .seek, issuedAt: issuedAt, position: position)
    }

    public static func setVolume(_ level: Double, id: UUID = UUID(), issuedAt: Date? = nil) -> RemoteCommand {
        RemoteCommand(id: id, kind: .setVolume, issuedAt: issuedAt, level: level)
    }

    public static func selectOutput(_ outputID: String, id: UUID = UUID(), issuedAt: Date? = nil) -> RemoteCommand {
        RemoteCommand(id: id, kind: .selectOutput, issuedAt: issuedAt, outputID: outputID)
    }

    /// False when `issuedAt` is missing: the temporary contract never sent it.
    public func isExpired(at now: Date, maximumAge: TimeInterval = RemoteCommand.maximumAge) -> Bool {
        guard let issuedAt else { return false }
        return now.timeIntervalSince(issuedAt) > maximumAge
    }

    /// True when the command carries the value its kind needs, and that value
    /// is a number where one is expected. A command that fails this is
    /// rejected with `invalid_request` before anything is sent to Music.
    public var hasRequiredValue: Bool {
        switch kind {
        case .play, .pause, .next, .previous: true
        case .seek: position.map(\.isFinite) ?? false
        case .setVolume: level.map(\.isFinite) ?? false
        case .selectOutput: !(outputID ?? "").isEmpty
        }
    }
}

/// The Mac's answer to one `RemoteCommand`.
public struct CommandAck: Codable, Equatable, Sendable {
    public var commandID: UUID
    /// True only when Music.app took the command. Re-reading Music afterwards is
    /// the Mac's job; the new state follows as a `state` frame.
    public var accepted: Bool
    /// The revision of the Mac's playback after handling the command. The state
    /// frame carrying the result has this revision or a later one.
    public var revision: UInt64
    /// Why, when `accepted` is false.
    public var error: ProtocolError?

    public init(commandID: UUID, accepted: Bool, revision: UInt64, error: ProtocolError? = nil) {
        self.commandID = commandID
        self.accepted = accepted
        self.revision = revision
        self.error = error
    }

    public static func accepted(_ commandID: UUID, revision: UInt64) -> CommandAck {
        CommandAck(commandID: commandID, accepted: true, revision: revision)
    }

    public static func rejected(_ commandID: UUID, revision: UInt64, _ error: ProtocolError) -> CommandAck {
        CommandAck(commandID: commandID, accepted: false, revision: revision, error: error)
    }
}

// MARK: - HTTP bodies (phone ↔ relay)

/// Body of `POST /v1/commands`. Send `Idempotency-Key: <command.id>` with it.
public struct CommandRequest: Codable, Equatable, Sendable {
    public var command: RemoteCommand
    /// The Now Playing session the command was issued from: the extension's
    /// `MacPlaybackAttributes.id`. Required by the relay, which refuses a
    /// command for any session but the current one, so a stale Lock Screen
    /// can't skip a track in a newer session.
    public var sessionID: String?
    public init(command: RemoteCommand, sessionID: String? = nil) {
        self.command = command
        self.sessionID = sessionID
    }
}

/// `200` body of `POST /v1/commands`.
public struct CommandResponse: Codable, Equatable, Sendable {
    public var ack: CommandAck
    public init(ack: CommandAck) { self.ack = ack }
}

/// Body of every non-2xx relay response.
public struct ErrorResponse: Codable, Equatable, Sendable {
    public var error: ProtocolError
    public init(error: ProtocolError) { self.error = error }
}
