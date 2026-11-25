import Foundation

/// Whether a playlist or album that Apple Music's recently played lists is
/// really what a queue came from, rather than just something that has the
/// song. A song's own album always has it, and can sit in recently played
/// ahead of the playlist: on 19 November 2026 a Mac playing an Apple Music
/// playlist came back as the album the song is on, and the album was added
/// to the library. The songs that follow tell them apart.
///
/// Songs are compared by catalogue ID, or else by title and lead artist, as
/// the Mac has catalogue IDs only for songs in its library. On 25 November
/// 2026 a Mac playing an Apple Music playlist had IDs for 9 of its 18 next
/// songs; compared by those IDs alone, the playlist didn't match.
public enum ContainerMatch {
    /// How many following songs are compared.
    public static let compared = 3

    /// A song in a playlist or album here.
    public struct Song: Equatable, Sendable {
        /// Nil when Apple Music gives none.
        public var id: String?
        public var title: String
        public var artist: String?

        public init(id: String?, title: String, artist: String?) {
            self.id = id
            self.title = title
            self.artist = artist
        }
    }

    /// Where the Mac's song is in `container`, if the container is what the
    /// Mac's queue came from: the first place with the song whose next songs
    /// match (`accepts`). The song is found by `catalogID`, or else by
    /// `title` and `artist`: for a song outside the Mac's library, the phone's
    /// search can find it on another release than the one the playlist lists.
    public static func place(of catalogID: String, title: String? = nil, artist: String? = nil, in container: [Song],
                             following: [QueuedTrack], inOrder: Bool) -> Int? {
        let byID = container.indices.filter { container[$0].id == catalogID }
        let byName = title.map { title in
            container.indices.filter { !byID.contains($0) && isSame(container[$0], title: title, artist: artist ?? "") }
        } ?? []
        return (byID + byName).first { accepts(container, at: $0, following: following, inOrder: inOrder) }
    }

    /// `container` is the playlist's or album's songs in order, `index` where
    /// the song is in it, and `following` the songs queued after it.
    ///
    /// In order, the container's next songs must be those, one after another.
    /// Shuffled, the queue is in no order, so each of them must be somewhere
    /// in the container. With nothing queued to compare, or nothing the
    /// container can compare against (the song is its last), it passes: the
    /// check can only reject what it can see is different.
    public static func accepts(_ container: [Song], at index: Int, following: [QueuedTrack], inOrder: Bool) -> Bool {
        let queued = Array(following.prefix(compared))
        guard !queued.isEmpty else { return true }
        if inOrder {
            let next = container.dropFirst(index + 1).prefix(queued.count)
            guard !next.isEmpty else { return true }
            return zip(next, queued).allSatisfy { isSame($0, $1) }
        }
        return queued.allSatisfy { song in container.contains { isSame($0, song) } }
    }

    static func isSame(_ listed: Song, _ queued: QueuedTrack) -> Bool {
        if let id = listed.id, id == queued.catalogID { return true }
        return isSame(listed, title: queued.title, artist: queued.artist)
    }

    static func isSame(_ listed: Song, title: String, artist: String) -> Bool {
        let lead = CatalogCandidate.lead(artist)
        return CatalogCandidate.fold(listed.title) == CatalogCandidate.fold(title)
            && !lead.isEmpty && CatalogCandidate.fold(listed.artist ?? "").contains(lead)
    }
}
