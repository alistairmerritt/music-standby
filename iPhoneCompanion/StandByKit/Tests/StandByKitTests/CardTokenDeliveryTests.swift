import Foundation
import Testing
import StandByProtocol
@testable import StandByKit

/// Two cards for one song (26 November 2026): the one the relay doesn't know is ended.
@Suite struct CardTokenDeliveryTests {
    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [Error?]
        private(set) var sends = 0
        private(set) var waits = 0
        init(_ answers: [Error?]) { self.answers = answers }
        func send() throws {
            let answer: Error? = lock.withLock {
                sends += 1
                return answers.isEmpty ? nil : answers.removeFirst()
            }
            if let answer { throw answer }
        }
        func wait() { lock.withLock { waits += 1 } }
    }

    private let mismatch = TransportError.commandRejected(.activityMismatch)

    @Test func aTokenTheRelayTakesIsSent() async {
        let calls = Calls([nil])
        #expect(await CardTokenDelivery.deliver({ try calls.send() }, wait: { calls.wait() }) == .sent)
        #expect(calls.sends == 1 && calls.waits == 0)
    }

    @Test func aCardTheRelayIsStillRecordingIsAskedAboutAgain() async {
        let calls = Calls([mismatch, nil])
        #expect(await CardTokenDelivery.deliver({ try calls.send() }, wait: { calls.wait() }) == .sent,
                "an older relay records the card only once APNs answers")
        #expect(calls.sends == 2 && calls.waits == 1)
    }

    @Test func aCardTheRelayStillDoesntKnowIsNotTheRelays() async {
        let calls = Calls([mismatch, mismatch])
        #expect(await CardTokenDelivery.deliver({ try calls.send() }, wait: { calls.wait() }) == .notTheRelays)
        #expect(calls.sends == 2)
    }

    @Test func otherFailuresAreJustFailures() async {
        let calls = Calls([TransportError.notConnected])
        let outcome = await CardTokenDelivery.deliver({ try calls.send() }, wait: { calls.wait() })
        #expect(outcome == .failed(TransportError.notConnected.localizedDescription))
        #expect(calls.sends == 1, "not asked again: only a mismatch is")
    }
}
