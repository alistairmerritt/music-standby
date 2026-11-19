import Testing
@testable import StandByKit

@Suite struct ContainerMatchTests {
    private let playlist: [String?] = ["p1", "p2", "p3", "p4", "p5"]
    private let album: [String?] = ["p1", "a2", "a3", "a4", "a5"]

    @Test func aSongsOwnAlbumIsNotThePlaylistItCameFrom() {
        // Song p1 starts the playlist, and also an album whose next songs differ.
        #expect(ContainerMatch.accepts(playlist, at: 0, following: ["p2", "p3", "p4"], inOrder: true))
        #expect(!ContainerMatch.accepts(album, at: 0, following: ["p2", "p3", "p4"], inOrder: true))
    }

    @Test func theRightContainerIsAcceptedFromAnyPlace() {
        #expect(ContainerMatch.accepts(playlist, at: 2, following: ["p4", "p5"], inOrder: true))
        #expect(!ContainerMatch.accepts(playlist, at: 2, following: ["p5", "p4"], inOrder: true))
    }

    @Test func onlyTheFirstFewFollowingSongsAreCompared() {
        #expect(ContainerMatch.accepts(playlist, at: 0, following: ["p2", "p3", "p4", "elsewhere"], inOrder: true))
    }

    @Test func shuffledOnlyNeedsTheSongsToBeInThereSomewhere() {
        #expect(ContainerMatch.accepts(playlist, at: 0, following: ["p5", "p2", "p4"], inOrder: false))
        #expect(!ContainerMatch.accepts(album, at: 0, following: ["p5", "p2", "p4"], inOrder: false))
    }

    @Test func nothingToCompareAcceptsWhatItCannotTellApart() {
        #expect(ContainerMatch.accepts(album, at: 0, following: [], inOrder: true), "a station lists one song, or none")
        #expect(ContainerMatch.accepts(playlist, at: 4, following: ["x"], inOrder: true), "the last song has nothing after it to compare")
    }

    @Test func aSongWithoutACatalogueIDInTheContainerIsAMismatch() {
        let gaps: [String?] = ["p1", nil, "p3"]
        #expect(!ContainerMatch.accepts(gaps, at: 0, following: ["p2", "p3"], inOrder: true))
    }
}
