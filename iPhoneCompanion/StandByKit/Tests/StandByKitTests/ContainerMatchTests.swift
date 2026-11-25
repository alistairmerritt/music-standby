import Testing
@testable import StandByKit

@Suite struct ContainerMatchTests {
    private func listed(_ id: String?, _ title: String? = nil, by artist: String = "Artist") -> ContainerMatch.Song {
        ContainerMatch.Song(id: id, title: title ?? "Title \(id ?? "?")", artist: artist)
    }
    /// A song in the Mac's Up Next: `id` nil for one outside the Mac's library.
    private func queued(_ id: String?, _ title: String? = nil, by artist: String = "Artist") -> QueuedTrack {
        QueuedTrack(catalogID: id, title: title ?? "Title \(id ?? "?")", artist: artist, duration: 200)
    }
    private var playlist: [ContainerMatch.Song] { ["p1", "p2", "p3", "p4", "p5"].map { listed($0) } }
    private var album: [ContainerMatch.Song] { ["p1", "a2", "a3", "a4", "a5"].map { listed($0) } }

    @Test func aSongsOwnAlbumIsNotThePlaylistItCameFrom() {
        // Song p1 starts the playlist, and also an album whose next songs differ.
        #expect(ContainerMatch.accepts(playlist, at: 0, following: ["p2", "p3", "p4"].map { queued($0) }, inOrder: true))
        #expect(!ContainerMatch.accepts(album, at: 0, following: ["p2", "p3", "p4"].map { queued($0) }, inOrder: true))
    }

    @Test func theRightContainerIsAcceptedFromAnyPlace() {
        #expect(ContainerMatch.accepts(playlist, at: 2, following: [queued("p4"), queued("p5")], inOrder: true))
        #expect(!ContainerMatch.accepts(playlist, at: 2, following: [queued("p5"), queued("p4")], inOrder: true))
    }

    @Test func onlyTheFirstFewFollowingSongsAreCompared() {
        #expect(ContainerMatch.accepts(playlist, at: 0, following: ["p2", "p3", "p4", "elsewhere"].map { queued($0) }, inOrder: true))
    }

    @Test func shuffledOnlyNeedsTheSongsToBeInThereSomewhere() {
        #expect(ContainerMatch.accepts(playlist, at: 0, following: ["p5", "p2", "p4"].map { queued($0) }, inOrder: false))
        #expect(!ContainerMatch.accepts(album, at: 0, following: ["p5", "p2", "p4"].map { queued($0) }, inOrder: false))
    }

    @Test func nothingToCompareAcceptsWhatItCannotTellApart() {
        #expect(ContainerMatch.accepts(album, at: 0, following: [], inOrder: true), "a station lists one song, or none")
        #expect(ContainerMatch.accepts(playlist, at: 4, following: [queued("x")], inOrder: true), "the last song has nothing after it to compare")
    }

    @Test func aSongWithoutACatalogueIDInTheContainerMatchesOnlyByName() {
        let gaps = [listed("p1"), listed(nil, "Something Else"), listed("p3")]
        #expect(!ContainerMatch.accepts(gaps, at: 0, following: [queued("p2"), queued("p3")], inOrder: true))
        let named = [listed("p1"), listed(nil, "Title p2"), listed("p3")]
        #expect(ContainerMatch.accepts(named, at: 0, following: [queued("p2"), queued("p3")], inOrder: true))
    }

    /// 25 November 2026: the Mac had catalogue IDs for 9 of its 18 next
    /// songs, the ones in its library, and the playlist didn't match.
    @Test func theMacsSongsWithoutCatalogueIDsMatchByTitleAndArtist() {
        let following = [queued(nil, "Title p2"), queued("p3"), queued(nil, "TITLE P4")]
        #expect(ContainerMatch.accepts(playlist, at: 0, following: following, inOrder: true))
        #expect(!ContainerMatch.accepts(album, at: 0, following: following, inOrder: true))
        #expect(ContainerMatch.accepts(playlist, at: 0, following: following.reversed(), inOrder: false))
        #expect(!ContainerMatch.accepts(album, at: 0, following: following.reversed(), inOrder: false))
    }

    @Test func aMatchByTitleNeedsTheSameLeadArtist() {
        #expect(!ContainerMatch.accepts(playlist, at: 0, following: [queued(nil, "Title p2", by: "A Cover Band")], inOrder: true))
        let featuring = [listed("p1"), listed("p2", by: "Artist & Friend")]
        #expect(ContainerMatch.accepts(featuring, at: 0, following: [queued(nil, "Title p2", by: "Artist")], inOrder: true))
        #expect(!ContainerMatch.accepts(playlist, at: 0, following: [queued(nil, "Title p2", by: "")], inOrder: true),
                "no artist to compare")
    }

    /// The phone's search can find a song outside the Mac's library on another
    /// release than the playlist's (the "[Mixed]" one, 25 November 2026).
    @Test func theSongIsFoundUnderThePlaylistsOwnID() {
        #expect(ContainerMatch.place(of: "found-here", title: "Title p3", artist: "Artist", in: playlist,
                                     following: [queued("p4")], inOrder: true) == 2)
        #expect(ContainerMatch.place(of: "found-here", in: playlist, following: [queued("p4")], inOrder: true) == nil,
                "without its title, only its ID finds it")
        #expect(ContainerMatch.place(of: "p3", in: playlist, following: [queued("p4")], inOrder: true) == 2)
    }

    @Test func aSongTwiceIsTakenWhereItsNextSongsMatch() {
        let twice = [listed("p1"), listed("p2"), listed("x"), listed("p1"), listed("p3")]
        #expect(ContainerMatch.place(of: "p1", in: twice, following: [queued("p3")], inOrder: true) == 3)
        #expect(ContainerMatch.place(of: "p1", in: twice, following: [queued("y")], inOrder: true) == nil, "neither place matches")
        #expect(ContainerMatch.place(of: "p1", in: album, following: [queued("p2")], inOrder: true) == nil, "the song's own album")
    }
}
