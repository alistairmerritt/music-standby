import Foundation
import Testing
@testable import CompanionCore

/// `RelayTransport.ping`: one answer per ping, however URLSession calls back.
@Suite struct RelayPingTests {
    struct Dropped: Error {}

    @Test func aPongAnswersTrue() async {
        let answered = await RelayTransport.ping(deadline: .seconds(5)) { handler in handler(nil) }
        #expect(answered)
    }

    @Test func aPingErrorAnswersFalse() async {
        let answered = await RelayTransport.ping(deadline: .seconds(5)) { handler in handler(Dropped()) }
        #expect(!answered)
    }

    /// The crash from 10 Nov: the handler called again as the socket closed.
    @Test func aSecondCallbackIsIgnored() async {
        let answered = await RelayTransport.ping(deadline: .seconds(5)) { handler in
            handler(nil)
            handler(Dropped())
            DispatchQueue.global().async { handler(Dropped()) }
        }
        #expect(answered)
        try? await Task.sleep(for: .milliseconds(50))   // let the late callback land
    }

    /// A dead connection never calls back; the deadline has to answer on its own.
    @Test func noPongAnswersFalseAtTheDeadline() async {
        let started = ContinuousClock.now
        let answered = await RelayTransport.ping(deadline: .milliseconds(100)) { _ in }
        #expect(!answered)
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test func aPongAfterTheDeadlineIsIgnored() async {
        let answered = await RelayTransport.ping(deadline: .milliseconds(50)) { handler in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { handler(nil) }
        }
        #expect(!answered)
        try? await Task.sleep(for: .milliseconds(300))   // let the late pong land
    }

    @Test func cancellingAnswersFalse() async {
        let ping = Task { await RelayTransport.ping(deadline: .seconds(30)) { _ in } }
        try? await Task.sleep(for: .milliseconds(50))
        ping.cancel()
        let started = ContinuousClock.now
        #expect(await !ping.value)
        #expect(ContinuousClock.now - started < .seconds(2))
    }
}
