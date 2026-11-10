import Foundation
import os
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

    /// The artwork to show, if any. The relay sends `""` for a track without
    /// artwork, because a field the system can't decode loses the whole push.
    public var artworkReference: String? {
        guard let artworkID, !artworkID.isEmpty else { return nil }
        return artworkID
    }

    private enum CodingKeys: String, CodingKey { case id, title, artist, album, duration, artworkID, artworkURL }

    // `artworkURL` is read and written as a plain string. Only JSONDecoder
    // treats a URL as a string; URL's own Codable expects {"relative": …}, so
    // any other decoder the system uses for a push would reject the field.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        artist = try c.decode(String.self, forKey: .artist)
        album = try c.decode(String.self, forKey: .album)
        duration = try c.decode(TimeInterval.self, forKey: .duration)
        artworkID = try c.decodeIfPresent(String.self, forKey: .artworkID)
        if let text = try? c.decodeIfPresent(String.self, forKey: .artworkURL) {
            artworkURL = URL(string: text)
        } else {
            artworkURL = try c.decodeIfPresent(URL.self, forKey: .artworkURL)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(artist, forKey: .artist)
        try c.encode(album, forKey: .album)
        try c.encode(duration, forKey: .duration)
        try c.encodeIfPresent(artworkID, forKey: .artworkID)
        try c.encodeIfPresent(artworkURL?.absoluteString, forKey: .artworkURL)
    }
}

/// Why attributes couldn't be decoded, as an error that can cross XPC.
///
/// On iOS 27.2 the Now Playing framework sends a decoding error back to
/// mediaremoted, and a `DecodingError` carries its coding path (CodingKey
/// values) in `userInfo`, which NSXPC refuses to encode: the extension then
/// aborts, and every push is lost. This one carries only a string.
public struct AttributesDecodingFailure: LocalizedError, CustomStringConvertible {
    public let description: String
    public var errorDescription: String? { description }
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

    private enum CodingKeys: String, CodingKey { case id, macName, revision, isPlaying, elapsedTime, timestamp, track, canGoNext, canGoPrevious }

    private static let logger = Logger(subsystem: "com.alistairmerritt.MusicStandBy", category: "attributes")

    // The system decodes a push's `attributes` with a decoder whose date
    // strategy isn't documented. The relay sends the Mac's ISO-8601 time with
    // milliseconds, which JSONDecoder's `.iso8601` rejects and its default
    // (seconds since 2001) can't read. So `timestamp` is read and written as a
    // string here, whatever the decoder's settings.
    public init(from decoder: any Decoder) throws {
        do {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            macName = try c.decode(String.self, forKey: .macName)
            revision = try c.decode(UInt64.self, forKey: .revision)
            isPlaying = try c.decode(Bool.self, forKey: .isPlaying)
            elapsedTime = try c.decode(TimeInterval.self, forKey: .elapsedTime)
            timestamp = try Self.decodeDate(c, forKey: .timestamp)
            track = try c.decodeIfPresent(SessionTrack.self, forKey: .track)
            canGoNext = try c.decode(Bool.self, forKey: .canGoNext)
            canGoPrevious = try c.decode(Bool.self, forKey: .canGoPrevious)
        } catch {
            let reason = Self.explain(error)
            Self.logger.error("Couldn't decode attributes: \(reason, privacy: .public)")
            throw AttributesDecodingFailure(description: reason)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(macName, forKey: .macName)
        try c.encode(revision, forKey: .revision)
        try c.encode(isPlaying, forKey: .isPlaying)
        try c.encode(elapsedTime, forKey: .elapsedTime)
        try c.encode(StandByWire.formatDate(timestamp), forKey: .timestamp)
        try c.encodeIfPresent(track, forKey: .track)
        try c.encode(canGoNext, forKey: .canGoNext)
        try c.encode(canGoPrevious, forKey: .canGoPrevious)
    }

    /// An ISO-8601 string, with or without fractional seconds; otherwise a
    /// native date, for a decoder that has one (a property list's).
    private static func decodeDate(_ c: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) throws -> Date {
        if let text = try? c.decode(String.self, forKey: key) {
            guard let date = StandByWire.parseDate(text) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "Expected an ISO-8601 date, got \(text)")
            }
            return date
        }
        return try c.decode(Date.self, forKey: key)
    }

    private static func explain(_ error: any Error) -> String {
        guard let error = error as? DecodingError else { return String(describing: error) }
        let context: DecodingError.Context
        var keys: [String] = []
        switch error {
        case .typeMismatch(_, let c), .valueNotFound(_, let c), .dataCorrupted(let c): context = c
        case .keyNotFound(let key, let c): context = c; keys = [key.stringValue]
        @unknown default: return String(describing: error)
        }
        let path = (context.codingPath.map(\.stringValue) + keys).joined(separator: ".")
        return "\(path.isEmpty ? "(top level)" : path): \(context.debugDescription)"
    }
}

#if canImport(NowPlaying) && os(iOS)
extension MacPlaybackAttributes: RemoteMediaSessionAttributes {}
#endif
