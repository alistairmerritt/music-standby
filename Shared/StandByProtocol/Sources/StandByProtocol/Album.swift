import Foundation

/// A song's place in an album in the library, so Continue on Mac carries the
/// album on from the song instead of starting the song's station.
///
/// Music on the Mac plays a library album from any song in album order (its
/// remote protocol's `cue`, seen 17 November 2026), counting songs by disc,
/// then track. It can't shuffle within the album: shuffle there draws from
/// the whole library. So a shuffled album continues in order on the Mac.
/// Added 17 November 2026; an older Mac ignores it and plays the station.
public struct AlbumPlace: Codable, Equatable, Sendable {
    /// The album's title, as both devices show it. The Mac finds the album
    /// by the song's catalogue ID; this is for logs and checks.
    public var title: String
    public var artist: String?
    /// How many of its songs the sender's library has.
    public var count: Int
    /// The song's place among them, from 0, by disc, then track.
    public var index: Int
    /// True when the sender was shuffling the album. Nil means not shuffled.
    public var shuffled: Bool?
    /// As `PlaylistPlace.addedToLibrary`: an Apple Music album the phone
    /// added to the library just now, for the Mac to wait for.
    public var addedToLibrary: Bool?

    public init(title: String, artist: String? = nil, count: Int, index: Int, shuffled: Bool? = nil, addedToLibrary: Bool? = nil) {
        self.title = title
        self.artist = artist
        self.count = count
        self.index = index
        self.shuffled = shuffled
        self.addedToLibrary = addedToLibrary
    }

    /// False for a place that can't be in any album: a receiver ignores it.
    public var isValid: Bool {
        !title.isEmpty && title.count <= PlaylistPlace.maximumNameLength
            && (1...PlaylistPlace.maximumCount).contains(count) && (0..<count).contains(index)
    }

    public var isShuffled: Bool { shuffled == true }
}
