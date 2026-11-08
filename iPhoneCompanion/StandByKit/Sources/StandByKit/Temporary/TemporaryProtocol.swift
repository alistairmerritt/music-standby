import Foundation

// TEMPORARY. These types stand in for the shared protocol the Mac developer will
// publish on `main`. They are not a proposal for it. When the shared models land,
// delete this folder and update `MacPlaybackAttributes+Message.swift` and
// `MockTransport.swift`; nothing else should reference these fields directly.

public struct TrackMetadata: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var artist: String
    public var album: String
    public var duration: TimeInterval
    public var artworkID: String

    public init(id: String, title: String, artist: String, album: String, duration: TimeInterval, artworkID: String) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.artworkID = artworkID
    }
}

public struct PlaybackMessage: Codable, Equatable, Sendable {
    public var revision: UInt64
    public var isPlaying: Bool
    public var elapsedTime: TimeInterval
    public var capturedAt: Date
    public var track: TrackMetadata?
    public var canGoNext: Bool
    public var canGoPrevious: Bool

    public init(revision: UInt64, isPlaying: Bool, elapsedTime: TimeInterval, capturedAt: Date, track: TrackMetadata?, canGoNext: Bool, canGoPrevious: Bool) {
        self.revision = revision
        self.isPlaying = isPlaying
        self.elapsedTime = elapsedTime
        self.capturedAt = capturedAt
        self.track = track
        self.canGoNext = canGoNext
        self.canGoPrevious = canGoPrevious
    }
}

public enum CommandKind: String, Codable, Sendable, CaseIterable {
    case play, pause, next, previous
}

public struct RemoteCommand: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var kind: CommandKind

    public init(id: UUID = UUID(), kind: CommandKind) {
        self.id = id
        self.kind = kind
    }
}

public struct CommandAck: Codable, Equatable, Sendable {
    public var commandID: UUID
    public var accepted: Bool
    public var revision: UInt64

    public init(commandID: UUID, accepted: Bool, revision: UInt64) {
        self.commandID = commandID
        self.accepted = accepted
        self.revision = revision
    }
}

public struct PairedMac: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}
