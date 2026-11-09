import Foundation

/// The four controls the iPhone offers. Unchanged from the temporary contract.
/// A new case is a breaking change and needs a protocol version bump.
public enum CommandKind: String, Codable, Sendable, CaseIterable {
    case play, pause, next, previous
}

/// A playback command from the phone, forwarded to the Mac by the relay.
public struct RemoteCommand: Codable, Equatable, Sendable, Identifiable {
    /// Also the relay's idempotency key. A repeated id must not act twice.
    public var id: UUID
    public var kind: CommandKind
    /// When the phone issued it. The Mac refuses commands older than
    /// `maximumAge`: a pause that arrives a minute late is worse than none.
    public var issuedAt: Date?

    public static let maximumAge: TimeInterval = 10

    public init(id: UUID = UUID(), kind: CommandKind, issuedAt: Date? = nil) {
        self.id = id
        self.kind = kind
        self.issuedAt = issuedAt
    }

    /// False when `issuedAt` is missing: the temporary contract never sent it.
    public func isExpired(at now: Date, maximumAge: TimeInterval = RemoteCommand.maximumAge) -> Bool {
        guard let issuedAt else { return false }
        return now.timeIntervalSince(issuedAt) > maximumAge
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
    public init(command: RemoteCommand) { self.command = command }
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
