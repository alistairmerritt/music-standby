import Foundation
import Testing
import StandByProtocol
@testable import CompanionCore

@Suite struct ReadErrorHoldTests {
    private let song = MusicTrack(title: "Losing My Edge", artist: "LCD Soundsystem", album: "LCD Soundsystem", duration: 473.114, persistentID: "542CEB17C137B39E")

    private func read(_ state: PlaybackState, at t: Double) -> MusicSnapshot {
        MusicSnapshot(state: state, capturedAt: Date(timeIntervalSince1970: t),
                      track: state == .playing || state == .paused ? song : nil,
                      detail: state == .error ? "AppleEvent timed out. (-1712)" : nil)
    }

    @Test func failuresWithinTheWindowAreHeld() {
        var hold = ReadErrorHold(window: 10)
        let good = read(.playing, at: 0)
        let h1 = hold.holds(read(.error, at: 3), lastGood: good)
        #expect(h1)
        let h2 = hold.holds(read(.error, at: 6), lastGood: good)
        #expect(h2)
        let h3 = hold.holds(read(.error, at: 12.9), lastGood: good)
        #expect(h3)   // 9.9 s after the first failure
        let h4 = hold.holds(read(.error, at: 13), lastGood: good)
        #expect(!h4)    // 10 s: Music really is stuck
    }

    @Test func aPausedSongIsHeldToo() {
        var hold = ReadErrorHold()
        let h5 = hold.holds(read(.error, at: 1), lastGood: read(.paused, at: 0))
        #expect(h5)
    }

    @Test func aGoodReadStartsTheWindowAgain() {
        var hold = ReadErrorHold(window: 10)
        let good = read(.playing, at: 0)
        let h6 = hold.holds(read(.error, at: 3), lastGood: good)
        #expect(h6)
        let h7 = hold.holds(read(.playing, at: 9), lastGood: good)
        #expect(!h7)
        let h8 = hold.holds(read(.error, at: 15), lastGood: read(.playing, at: 9))
        #expect(h8)   // 0 s into a new run
    }

    @Test func nothingToKeepMeansNothingIsHeld() {
        var hold = ReadErrorHold()
        let h9 = hold.holds(read(.error, at: 1), lastGood: nil)
        #expect(!h9)
        let h10 = hold.holds(read(.error, at: 1), lastGood: read(.stopped, at: 0))
        #expect(!h10)
        let h11 = hold.holds(read(.error, at: 1), lastGood: read(.notRunning, at: 0))
        #expect(!h11)
    }

    @Test func permissionAndQuitAreNeverHeld() {
        var hold = ReadErrorHold()
        let good = read(.playing, at: 0)
        let h12 = hold.holds(read(.automationDenied, at: 1), lastGood: good)
        #expect(!h12)
        let h13 = hold.holds(read(.notRunning, at: 2), lastGood: good)
        #expect(!h13)
    }
}
