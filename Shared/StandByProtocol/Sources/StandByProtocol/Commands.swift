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
    /// Play Apple Music's station for the song whose catalogue ID is
    /// `RemoteCommand.catalogID` (the catalogue's Create Station): Continue
    /// on Mac for a song the Mac's queue doesn't have, which Music on the Mac
    /// can't be told to play. Music usually starts the station with that
    /// song. Added 15 November 2026; an older Mac answers `unsupported_command`.
    case playStation

    /// The field a command of this kind must carry, if any.
    public var requiredValue: String? {
        switch self {
        case .play, .pause, .next, .previous: nil
        case .seek: "position"
        case .setVolume: "level"
        case .selectOutput: "outputID"
        case .playStation: "catalogID"
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
    /// An Apple Music catalogue song ID, all digits, for `playStation`.
    public var catalogID: String?
    /// The song's title, for `playStation`: the Mac seeks to `position`
    /// only when the station starts with a song of this title (16 November
    /// 2026). For `playStation`, `position` is where the phone was at
    /// `issuedAt`; the Mac adds the time since, as the phone plays on.
    public var title: String?
    /// Why the phone sent it, when that matters to the Mac. Added 12 November
    /// 2026; an older Mac ignores it.
    public var reason: CommandReason?
    /// For `playStation`: the library playlist the phone plays the song from.
    /// A Mac connected to Music plays that playlist from the song instead of
    /// the station, and shuffles the rest when `shuffled`; without it, or
    /// when the Mac's library doesn't have the playlist with the song, the
    /// station as before. Added 17 November 2026; an older Mac ignores it.
    public var playlist: PlaylistPlace?
    /// For `playStation`, when `playlist` is nil: the library album the phone
    /// plays the song from. A Mac connected to Music that has the song plays
    /// the album on from it, in album order; otherwise the station. Added 17
    /// November 2026; an older Mac ignores it.
    public var album: AlbumPlace?
    /// For `playStation`: the Apple Music station the phone plays. The Mac
    /// plays that station, which starts on another song, rather than a
    /// station made from the song (17 November 2026).
    public var station: StationPlace?
    /// For `playStation`: the phone shuffles its whole library (a guess:
    /// iOS doesn't say). The Mac plays the song, then shuffles its library.
    public var shuffledLibrary: Bool?
    /// For `playStation`: the phone's repeat setting, for Music to follow.
    public var repeatMode: RepeatMode?

    public static let maximumAge: TimeInterval = 10

    public init(id: UUID = UUID(), kind: CommandKind, issuedAt: Date? = nil,
                position: TimeInterval? = nil, level: Double? = nil, outputID: String? = nil,
                catalogID: String? = nil, title: String? = nil, reason: CommandReason? = nil, playlist: PlaylistPlace? = nil,
                album: AlbumPlace? = nil, station: StationPlace? = nil, shuffledLibrary: Bool? = nil, repeatMode: RepeatMode? = nil) {
        self.id = id
        self.kind = kind
        self.issuedAt = issuedAt
        self.position = position
        self.level = level
        self.outputID = outputID
        self.catalogID = catalogID
        self.title = title
        self.reason = reason
        self.playlist = playlist
        self.album = album
        self.station = station
        self.shuffledLibrary = shuffledLibrary
        self.repeatMode = repeatMode
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

    /// With `position` and `title`, the Mac seeks there itself once the
    /// station starts with that song, rather than after the phone sees it
    /// play (16 November 2026). With `playlist`, a Mac that has it plays the
    /// playlist from the song instead (17 November 2026).
    public static func playStation(seededBy catalogID: String, position: TimeInterval? = nil, title: String? = nil,
                                   playlist: PlaylistPlace? = nil, album: AlbumPlace? = nil, station: StationPlace? = nil,
                                   shuffledLibrary: Bool? = nil, repeatMode: RepeatMode? = nil,
                                   id: UUID = UUID(), issuedAt: Date? = nil) -> RemoteCommand {
        RemoteCommand(id: id, kind: .playStation, issuedAt: issuedAt, position: position, catalogID: catalogID, title: title,
                      playlist: playlist, album: album, station: station, shuffledLibrary: shuffledLibrary, repeatMode: repeatMode)
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
        // Digits only: it becomes part of a URL on the Mac.
        case .playStation: catalogID.map { !$0.isEmpty && $0.count <= 20 && $0.allSatisfy { $0.isASCII && $0.isNumber } } ?? false
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
    /// `MacPlaybackAttributes.id`. The relay refuses a command naming any
    /// session but the current one, so a stale Lock Screen can't skip a track
    /// in a newer session. Nil from the app and its actions when the relay has
    /// no session: the relay forwards those anyway (16 November 2026).
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
