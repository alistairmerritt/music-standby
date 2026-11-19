import Foundation

/// A song's place in a library playlist, so a hand-over carries the playlist
/// itself: Continue on Mac plays the playlist from the song instead of the
/// song's station, and Continue on iPhone plays it instead of 25 of its songs.
///
/// Library playlists sync between the Mac and the iPhone through iCloud Music
/// Library, in the same order: on 17 November 2026 a 123-song playlist had
/// the same songs in the same places on both. Each side still checks that
/// the song is where `index` says before trusting it, and looks nearby when
/// it isn't.
/// Added 17 November 2026; an older Mac or iPhone ignores it.
public struct PlaylistPlace: Codable, Equatable, Sendable {
    /// The playlist's name, as both devices show it.
    public var name: String
    /// Apple Music's ID for the playlist when the sender knows it: `pl.u-…`
    /// for a library playlist, as the iPhone reads it. The Mac can't read
    /// one. Only a hint: see `knownCloudID`.
    public var cloudID: String?
    /// How many songs it has, to tell playlists with the same name apart.
    public var count: Int
    /// The song's place in it, from 0.
    public var index: Int
    /// True when the sender was shuffling the playlist: the receiver starts
    /// with the song and shuffles the rest. Nil means not shuffled.
    public var shuffled: Bool?
    /// True when the phone added this Apple Music playlist to the library
    /// just now, for Continue on Mac: the Mac waits up to `librarySyncWait`
    /// for it to arrive. It took 4 s on 17 November 2026.
    public var addedToLibrary: Bool?

    /// How long a Mac waits for a playlist or album the phone has just added.
    public static let librarySyncWait: TimeInterval = 25

    public init(name: String, cloudID: String? = nil, count: Int, index: Int, shuffled: Bool? = nil, addedToLibrary: Bool? = nil) {
        self.name = name
        // iOS gives "" for a playlist without one (a six-song playlist, 17 November 2026).
        self.cloudID = cloudID?.isEmpty == false ? cloudID : nil
        self.count = count
        self.index = index
        self.shuffled = shuffled
        self.addedToLibrary = addedToLibrary
    }

    public static let maximumNameLength = 256
    public static let maximumCount = 100_000

    /// False for a place that can't be in any playlist: a receiver ignores it
    /// and carries on as if it hadn't been sent. `cloudID` doesn't count: a
    /// bad one is only ignored (`knownCloudID`).
    public var isValid: Bool {
        !name.isEmpty && name.count <= Self.maximumNameLength
            && (1...Self.maximumCount).contains(count) && (0..<count).contains(index)
    }

    /// `cloudID`, unless it's empty or too long to be one.
    public var knownCloudID: String? {
        cloudID.flatMap { $0.isEmpty || $0.count > 64 ? nil : $0 }
    }

    public var isShuffled: Bool { shuffled == true }

    /// Where `catalogID` is in a playlist whose songs have these catalogue
    /// IDs: `index` when the song is there, or else the closest place it is,
    /// as when the playlist changed on one device and hasn't synced yet. Nil
    /// when the playlist doesn't have the song.
    public func locate(_ catalogID: String, in catalogIDs: [String?]) -> Int? {
        if catalogIDs.indices.contains(index), catalogIDs[index] == catalogID { return index }
        return catalogIDs.indices.filter { catalogIDs[$0] == catalogID }.min { abs($0 - index) < abs($1 - index) }
    }
}
