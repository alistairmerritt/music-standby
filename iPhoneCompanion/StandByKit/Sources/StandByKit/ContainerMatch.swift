import Foundation

/// Whether a playlist or album that Apple Music's recently played lists is
/// really what a queue came from, rather than just something that has the
/// song. A song's own album always has it, and can sit in recently played
/// ahead of the playlist: on 19 November 2026 a Mac playing an Apple Music
/// playlist came back as the album the song is on, and the album was added
/// to the library. The songs that follow tell them apart.
public enum ContainerMatch {
    /// How many following songs are compared.
    public static let compared = 3

    /// `container` is the playlist's or album's songs in order (nil for one
    /// without a catalogue ID), `index` where the song is in it, and
    /// `following` the catalogue IDs queued after the song.
    ///
    /// In order, the container's next songs must be those, one after another.
    /// Shuffled, the queue is in no order, so each of them must be somewhere
    /// in the container. With nothing queued to compare, or nothing the
    /// container can compare against (the song is its last), it passes: the
    /// check can only reject what it can see is different.
    public static func accepts(_ container: [String?], at index: Int, following: [String], inOrder: Bool) -> Bool {
        let queued = Array(following.prefix(compared))
        guard !queued.isEmpty else { return true }
        if inOrder {
            let next = container.dropFirst(index + 1).prefix(queued.count)
            guard !next.isEmpty else { return true }
            return zip(next, queued).allSatisfy { $0 == $1 }
        }
        let ids = Set(container.compactMap { $0 })
        return queued.allSatisfy(ids.contains)
    }
}
