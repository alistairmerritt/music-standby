import Foundation
import StandByProtocol

/// One track as Music.app reports it. Richer than the wire's `TrackMetadata`:
/// it keeps what the Mac needs locally (class, artwork count, raw ids).
public struct MusicTrack: Equatable, Sendable {
    public var title: String
    public var artist: String
    public var album: String
    /// Came back empty for streamed tracks in the spike. Never rely on it.
    public var albumArtist: String?
    public var duration: TimeInterval
    /// Stable within one Music.app run (verified). Unknown across restarts.
    public var persistentID: String?
    public var databaseID: Int?
    /// "file track", "URL track" (streamed catalogue), "shared track", …
    public var trackClass: String?
    public var artworkCount: Int

    public init(title: String, artist: String, album: String, albumArtist: String? = nil, duration: TimeInterval,
                persistentID: String? = nil, databaseID: Int? = nil, trackClass: String? = nil, artworkCount: Int = 0) {
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.duration = duration
        self.persistentID = persistentID
        self.databaseID = databaseID
        self.trackClass = trackClass
        self.artworkCount = artworkCount
    }

    /// The wire's song identity.
    public var trackID: String {
        TrackID.make(persistentID: persistentID, title: title, artist: artist, album: album, duration: duration)
    }
}

/// What Music.app is doing at one moment. States are the protocol's
/// `PlaybackState`, which uses the prototype's six values.
public struct MusicSnapshot: Equatable, Sendable {
    public var state: PlaybackState
    /// Seconds into the track at `capturedAt`.
    public var position: TimeInterval
    public var capturedAt: Date
    public var track: MusicTrack?
    /// AppleScript's message and number, for `.automationDenied` and `.error`.
    public var detail: String?

    public init(state: PlaybackState, position: TimeInterval = 0, capturedAt: Date, track: MusicTrack? = nil, detail: String? = nil) {
        self.state = state
        self.position = position
        self.capturedAt = capturedAt
        self.track = track
        self.detail = detail
    }

    public static func notRunning(at date: Date) -> MusicSnapshot {
        MusicSnapshot(state: .notRunning, capturedAt: date)
    }

    public static func failure(_ state: PlaybackState, _ detail: String, at date: Date) -> MusicSnapshot {
        MusicSnapshot(state: state, capturedAt: date, detail: detail)
    }

    public var isMusicRunning: Bool { state != .notRunning }
}

/// Parses the snapshot script's output: fields joined by U+001F, in the order
/// state, position, name, artist, album, album artist, duration, persistent ID,
/// database ID, class, artwork count. Same order as the tested `musicprobe.sh`.
public enum SnapshotParser {
    public static let separator = "\u{1f}"

    public static func parse(_ raw: String, capturedAt: Date) -> MusicSnapshot {
        var f = raw.components(separatedBy: separator)
        while f.count < 11 { f.append("") }
        let track: MusicTrack? = f[2].isEmpty ? nil : MusicTrack(
            title: f[2], artist: f[3], album: f[4],
            albumArtist: f[5].isEmpty ? nil : f[5],
            duration: number(f[6]) ?? 0,
            persistentID: f[7].isEmpty ? nil : f[7],
            databaseID: Int(f[8]),
            trackClass: f[9].isEmpty ? nil : f[9],
            artworkCount: Int(f[10]) ?? 0)
        return MusicSnapshot(state: state(f[0]), position: number(f[1]) ?? 0, capturedAt: capturedAt, track: track)
    }

    /// `player state as text`. Fast-forwarding and rewinding are still playing.
    static func state(_ text: String) -> PlaybackState {
        switch text {
        case "playing", "fast forwarding", "rewinding": .playing
        case "paused": .paused
        default: .stopped
        }
    }

    /// AppleScript writes reals with the user's decimal separator in some
    /// locales, so accept a comma.
    static func number(_ text: String) -> Double? {
        guard let value = Double(text.replacingOccurrences(of: ",", with: ".")), value.isFinite else { return nil }
        return value
    }
}
