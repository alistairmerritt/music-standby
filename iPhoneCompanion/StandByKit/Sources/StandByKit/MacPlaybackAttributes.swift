import Foundation
#if canImport(NowPlaying) && os(iOS)
import NowPlaying
#endif

public struct SessionTrack: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var artist: String
    public var album: String
    public var duration: TimeInterval
    public var artworkID: String?
    public var artworkURL: URL?

    public init(id: String, title: String, artist: String, album: String, duration: TimeInterval, artworkID: String?, artworkURL: URL? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.artworkID = artworkID
        self.artworkURL = artworkURL
    }
}

/// The state handed to the system and decoded by the Now Playing extension.
/// Pushes carry this as JSON, so artwork travels by reference and never inline.
public struct MacPlaybackAttributes: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var macName: String
    public var revision: UInt64
    public var isPlaying: Bool
    public var elapsedTime: TimeInterval
    public var timestamp: Date
    public var track: SessionTrack?
    public var canGoNext: Bool
    public var canGoPrevious: Bool

    public init(id: String, macName: String, revision: UInt64, isPlaying: Bool, elapsedTime: TimeInterval, timestamp: Date, track: SessionTrack?, canGoNext: Bool, canGoPrevious: Bool) {
        self.id = id
        self.macName = macName
        self.revision = revision
        self.isPlaying = isPlaying
        self.elapsedTime = elapsedTime
        self.timestamp = timestamp
        self.track = track
        self.canGoNext = canGoNext
        self.canGoPrevious = canGoPrevious
    }

    /// Position at `date`, extrapolated while playing and clamped to the track.
    public func elapsed(at date: Date) -> TimeInterval {
        let running = isPlaying ? max(0, date.timeIntervalSince(timestamp)) : 0
        let position = max(0, elapsedTime + running)
        guard let duration = track?.duration, duration > 0 else { return position }
        return min(position, duration)
    }

    /// Stale-update guard. A lower revision is rejected unless it is clearly
    /// newer in time, which is what a restarted Mac (revision reset) looks like.
    public func shouldBeReplaced(by incoming: MacPlaybackAttributes, restartTolerance: TimeInterval = 5) -> Bool {
        incoming.revision >= revision || incoming.timestamp > timestamp.addingTimeInterval(restartTolerance)
    }
}

#if canImport(NowPlaying) && os(iOS)
extension MacPlaybackAttributes: RemoteMediaSessionAttributes {}
#endif
