import Foundation
import Testing
@testable import StandByKit

/// StandBy asks for each new cover at two sizes at once; handed over together
/// they took the Now Playing extension past its memory limit (26 November 2026).
@MainActor
@Suite struct ArtworkHandoverGateTests {
    /// Pauses the test ends by hand, standing in for the settle time.
    actor Settles {
        private var pending: [CheckedContinuation<Void, Never>] = []
        func wait() async { await withCheckedContinuation { pending.append($0) } }
        func endOne() { if !pending.isEmpty { pending.removeFirst().resume() } }
        var count: Int { pending.count }
    }

    @Test func theSecondCoverWaitsUntilTheFirstIsHandedOverAndSettled() async {
        let settles = Settles()
        let gate = ArtworkHandoverGate(settle: .zero, sleep: { _ in await settles.wait() })
        #expect(await gate.enter() == false, "nothing ahead of the first")
        let second = Task { await gate.enter() }
        await eventually("the second waits") { await gate.waitingCount == 1 }

        await gate.leave()   // the first is handed over; the pause starts
        await eventually("the pause after the first") { await settles.count == 1 }
        #expect(await gate.waitingCount == 1, "still waiting during the pause")

        await settles.endOne()
        #expect(await second.value == true, "it went second")
        #expect(await gate.waitingCount == 0)
    }

    @Test func coversGoInTheOrderTheyWereAskedFor() async {
        let settles = Settles()
        let gate = ArtworkHandoverGate(settle: .zero, sleep: { _ in await settles.wait() })
        await gate.enter()
        var order: [String] = []
        let large = Task { @MainActor in
            await gate.enter()
            order.append("1200")
        }
        await eventually("the large waits") { await gate.waitingCount == 1 }
        let small = Task { @MainActor in
            await gate.enter()
            order.append("903")
        }
        await eventually("both wait") { await gate.waitingCount == 2 }
        await gate.leave()
        await eventually("a pause") { await settles.count == 1 }
        await settles.endOne()
        await large.value
        await gate.leave()
        await eventually("another pause") { await settles.count == 1 }
        await settles.endOne()
        await small.value
        #expect(order == ["1200", "903"])
    }

    @Test func onceThePauseIsOverTheNextGoesStraightIn() async {
        let settles = Settles()
        let gate = ArtworkHandoverGate(settle: .zero, sleep: { _ in await settles.wait() })
        await gate.enter()
        await gate.leave()
        await eventually("the pause") { await settles.count == 1 }
        await settles.endOne()
        // Nobody was waiting, so the gate is free once the pause is over.
        await eventually("free again") { await gate.waitingCount == 0 }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(await gate.enter() == false)
    }
}
