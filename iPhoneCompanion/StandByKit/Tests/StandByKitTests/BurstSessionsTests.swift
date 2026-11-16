import Foundation
import Testing
@testable import StandByKit

/// The extension's requests share a session within a burst (16 November 2026).
@Suite struct BurstSessionsTests {
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date = Date(timeIntervalSince1970: 1_000)
        var now: Date { lock.withLock { date } }
        func advance(_ seconds: TimeInterval) { lock.withLock { date += seconds } }
    }

    @Test func requestsInABurstShareASessionAndALaterOneGetsAFreshOne() {
        let clock = Clock()
        let bursts = BurstSessions(window: 1, now: { clock.now }, make: { URLSession(configuration: .ephemeral) })
        let command = bursts.begin()
        let state = bursts.begin()
        #expect(command === state, "in flight together")
        bursts.end()
        bursts.end()
        clock.advance(0.5)
        let artwork = bursts.begin()
        #expect(artwork === command, "within the window")
        bursts.end()
        clock.advance(1.5)
        let later = bursts.begin()
        #expect(later !== command, "after the window: the old socket may be dead")
        bursts.end()
    }
}
