import Foundation
import Testing
@testable import StandByProtocol

@Suite struct RevisionCounterTests {
    @Test func seedsFromTheClockInMilliseconds() {
        var counter = RevisionCounter(lastPersisted: nil, now: Date(timeIntervalSince1970: 1_794_207_600.5))
        #expect(counter.current == 1_794_207_600_500)
        #expect(counter.next() == 1_794_207_600_501)
        #expect(counter.next() == 1_794_207_600_502)
    }

    @Test func persistedValueWinsWhenTheClockIsBehind() {
        var counter = RevisionCounter(lastPersisted: 9_000_000_000_000, now: Date(timeIntervalSince1970: 1_794_207_600))
        #expect(counter.next() == 9_000_000_000_001)
    }

    /// The case the iOS app currently guesses at: the companion restarts.
    @Test func increasesAcrossARestart() {
        var first = RevisionCounter(lastPersisted: nil, now: Date(timeIntervalSince1970: 1000))
        var last: UInt64 = 0
        for _ in 0..<5000 { last = first.next() }   // a busy run, ahead of the clock
        var second = RevisionCounter(lastPersisted: last, now: Date(timeIntervalSince1970: 1001))
        #expect(second.next() > last)
        var lostStorage = RevisionCounter(lastPersisted: nil, now: Date(timeIntervalSince1970: 1060))
        #expect(lostStorage.next() > last)
    }

    @Test func staysInsideJavaScriptsSafeIntegerRange() {
        var counter = RevisionCounter(lastPersisted: nil, now: Date(timeIntervalSince1970: 4_102_444_800))  // 2100
        #expect(counter.next() < 9_007_199_254_740_991)
    }
}

@Suite struct ListeningSessionTests {
    private func ids() -> () -> UUID {
        var n = 0
        return {
            n += 1
            return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
        }
    }

    @Test func opensOnPlayAndSurvivesPausesAndErrors() {
        var tracker = ListeningSessionTracker()
        let make = ids()
        #expect(tracker.update(for: .paused, makeID: make) == nil)
        let opened = tracker.update(for: .playing, makeID: make)
        #expect(opened != nil)
        #expect(tracker.update(for: .paused, makeID: make) == opened)
        #expect(tracker.update(for: .error, makeID: make) == opened)
        #expect(tracker.update(for: .playing, makeID: make) == opened)
    }

    @Test(arguments: [PlaybackState.stopped, .notRunning, .automationDenied])
    func closesOnStopQuitOrDenial(_ ending: PlaybackState) {
        var tracker = ListeningSessionTracker()
        let make = ids()
        let first = tracker.update(for: .playing, makeID: make)
        #expect(tracker.update(for: ending, makeID: make) == nil)
        let second = tracker.update(for: .playing, makeID: make)
        #expect(second != nil)
        #expect(second != first)
    }

    /// Verified behaviour: after a Music restart, Music is stopped with no track.
    @Test func musicRestartEndsTheSession() {
        var tracker = ListeningSessionTracker()
        let make = ids()
        let before = tracker.update(for: .playing, makeID: make)
        _ = tracker.update(for: .notRunning, makeID: make)
        #expect(tracker.update(for: .stopped, makeID: make) == nil)
        #expect(tracker.update(for: .playing, makeID: make) != before)
    }

    @Test func stoppedIsTheOnlyOutcomeWithoutPlay() {
        var tracker = ListeningSessionTracker()
        for state in [PlaybackState.stopped, .paused, .error, .notRunning] {
            #expect(tracker.update(for: state) == nil)
        }
    }
}
