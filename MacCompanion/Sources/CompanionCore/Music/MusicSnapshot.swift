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
    /// Music's `sound volume`, 0–100. Nil when the read didn't include it.
    public var volume: Int?
    /// Music's AirPlay devices, in its order. Nil when the read didn't include them.
    public var outputs: [AudioOutput]?

    public init(state: PlaybackState, position: TimeInterval = 0, capturedAt: Date, track: MusicTrack? = nil, detail: String? = nil,
                volume: Int? = nil, outputs: [AudioOutput]? = nil) {
        self.state = state
        self.position = position
        self.capturedAt = capturedAt
        self.track = track
        self.detail = detail
        self.volume = volume
        self.outputs = outputs
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
/// Two more since 11 November 2026: sound volume, and the AirPlay devices
/// (one per U+001E; name, kind, selected, available, network address split by
/// U+001D). A shorter record, from an older script, leaves both nil.
public enum SnapshotParser {
    public static let separator = "\u{1f}"

    public static func parse(_ raw: String, capturedAt: Date) -> MusicSnapshot {
        var f = raw.components(separatedBy: separator)
        while f.count < 13 { f.append("") }
        let track: MusicTrack? = f[2].isEmpty ? nil : MusicTrack(
            title: f[2], artist: f[3], album: f[4],
            albumArtist: f[5].isEmpty ? nil : f[5],
            duration: number(f[6]) ?? 0,
            persistentID: f[7].isEmpty ? nil : f[7],
            databaseID: Int(f[8]),
            trackClass: f[9].isEmpty ? nil : f[9],
            artworkCount: Int(f[10]) ?? 0)
        return MusicSnapshot(state: state(f[0]), position: number(f[1]) ?? 0, capturedAt: capturedAt, track: track,
                             volume: Int(f[11]).map { min(100, max(0, $0)) }, outputs: outputs(f[12]))
    }

    /// Nil for an empty field: the script didn't read the devices, or there were none.
    static func outputs(_ text: String) -> [AudioOutput]? {
        let records = text.components(separatedBy: MusicScript.outputSeparator).filter { !$0.isEmpty }
        guard !records.isEmpty else { return nil }
        return records.map { record in
            var v = record.components(separatedBy: MusicScript.outputFieldSeparator)
            while v.count < 5 { v.append("") }
            let address = v[4] == "missing value" || v[4].isEmpty ? nil : v[4]
            return AudioOutput(id: AudioOutput.makeID(networkAddress: address, name: v[0]), name: v[0], kind: kind(v[1]),
                               isSelected: v[2] == "true", isAvailable: v[3] != "false")
        }
    }

    /// `kind of AirPlay device as text` → the wire's kind.
    static func kind(_ text: String) -> AudioOutput.Kind {
        switch text {
        case "computer": .computer
        case "AirPort Express": .airportExpress
        case "Apple TV": .appleTV
        case "AirPlay device": .airPlay
        case "Bluetooth device": .bluetooth
        case "HomePod": .homePod
        case "TV": .tv
        default: .unknown
        }
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
    /// locales, so accept a comma. Rounded to milliseconds: `properties` gives
    /// durations like 205.307006835938, which only add noise on the wire.
    static func number(_ text: String) -> Double? {
        guard let value = Double(text.replacingOccurrences(of: ",", with: ".")), value.isFinite else { return nil }
        return (value * 1000).rounded() / 1000
    }
}
