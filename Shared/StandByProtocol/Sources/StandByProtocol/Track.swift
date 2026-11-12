import CryptoKit
import Foundation

/// One song as the Mac sees it. Field names and types match the iOS app's
/// temporary `TrackMetadata`, except that `artworkID` is now optional.
public struct TrackMetadata: Codable, Equatable, Sendable {
    /// Song identity. Opaque to everyone but the Mac: compare for equality and
    /// nothing else. Built with `TrackID.make(…)`. Stable for as long as Music.app
    /// stays running; not guaranteed across a Music restart.
    public var id: String
    public var title: String
    public var artist: String
    public var album: String
    /// Seconds. `0` means unknown, as for a live stream.
    public var duration: TimeInterval
    /// `ArtworkID` of the album art, or nil when the track has none.
    public var artworkID: String?
    /// The song's Apple Music catalogue ID (Music's `com.apple.itunes.itms-songid`),
    /// the id `MPMusicPlayerController.setQueue(with:)` takes on the phone. Nil
    /// when the Mac can't tell: it needs the companion paired with Music as a
    /// remote, and the song in the Mac's library. Added 12 November 2026.
    public var catalogID: String?

    public init(id: String, title: String, artist: String, album: String, duration: TimeInterval, artworkID: String? = nil,
                catalogID: String? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.artworkID = artworkID
        self.catalogID = catalogID
    }
}

/// A song Music will play after the current one (its Up Next).
public struct QueuedTrack: Codable, Equatable, Sendable {
    /// Apple Music catalogue ID, as `TrackMetadata.catalogID`. Nil when unknown.
    public var catalogID: String?
    public var title: String
    public var artist: String
    /// Nil from a Mac that doesn't say.
    public var album: String?
    /// Seconds. `0` means unknown.
    public var duration: TimeInterval

    public init(catalogID: String?, title: String, artist: String, album: String? = nil, duration: TimeInterval) {
        self.catalogID = catalogID
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
    }
}

/// How the Mac builds `TrackMetadata.id`.
///
/// Music.app's `persistent ID` identifies a track within one run of Music and was
/// verified stable when revisiting a track. It is not known to survive a Music
/// restart, and a streamed track can't be reached after one anyway. When it is
/// missing, the id falls back to a hash of the descriptive fields.
public enum TrackID {
    /// `pid:<persistent ID>` when Music supplies one, otherwise `key:<32 hex>`.
    public static func make(persistentID: String?, title: String, artist: String, album: String, duration: TimeInterval) -> String {
        if let pid = persistentID?.trimmingCharacters(in: .whitespacesAndNewlines), !pid.isEmpty {
            return "pid:" + pid.uppercased()
        }
        let digest = SHA256.hash(data: Data(fallbackKey(title: title, artist: artist, album: album, duration: duration).utf8))
        return "key:" + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// `title|artist|album|whole seconds`. The identity that would survive a
    /// Music restart, if the track could be reached again.
    public static func fallbackKey(title: String, artist: String, album: String, duration: TimeInterval) -> String {
        let seconds = duration.isFinite ? Int(duration.rounded()) : 0
        return "\(title)|\(artist)|\(album)|\(seconds)"
    }
}
