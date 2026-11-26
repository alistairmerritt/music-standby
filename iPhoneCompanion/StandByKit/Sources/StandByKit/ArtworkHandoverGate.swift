import Foundation

/// One cover handed to iOS at a time, with a pause after each, for the Now
/// Playing extension.
///
/// StandBy asks for each new cover at two sizes at once (1200 and 903
/// points). When the cover wasn't cached yet, both requests waited on the
/// one download and were handed over in the same millisecond; iOS's work on
/// the two together took the extension past its limit of about 6 MB, and it
/// was killed before StandBy had the cover, which then never showed. Seen
/// twice in ten minutes on 26 November 2026 ("killed by jetsam reason
/// per-process-limit", 20 ms after "handed over", at 5.3–5.4 MB). One at a
/// time, the same covers peaked at 5.77 MB.
public actor ArtworkHandoverGate {
    /// How long after one cover is handed over the next may go. iOS's work
    /// on a cover follows the hand-over within milliseconds.
    public static let defaultSettle: Duration = .milliseconds(400)

    private let settle: Duration
    private let sleep: @Sendable (Duration) async -> Void
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    public init(settle: Duration = defaultSettle,
                sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.settle = settle
        self.sleep = sleep
    }

    /// Waits for this cover's turn. True when another cover went first.
    @discardableResult
    public func enter() async -> Bool {
        guard busy else {
            busy = true
            return false
        }
        await withCheckedContinuation { waiting.append($0) }
        return true
    }

    /// This cover is handed over (or failed): the next may go once `settle`
    /// has passed. Pair every `enter()` with one `leave()`.
    public func leave() {
        let settle = settle, sleep = sleep
        Task {
            await sleep(settle)
            self.next()
        }
    }

    private func next() {
        if waiting.isEmpty {
            busy = false
        } else {
            waiting.removeFirst().resume()
        }
    }

    /// How many covers are waiting their turn.
    public var waitingCount: Int { waiting.count }
}
