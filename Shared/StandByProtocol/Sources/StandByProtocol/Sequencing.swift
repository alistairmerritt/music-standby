import Foundation

/// Produces `PlaybackMessage.revision` values on the Mac.
///
/// **Rule:** revisions from one Mac only ever increase, including across
/// restarts of the companion app. Each run starts at
/// `max(last persisted revision, Unix time in milliseconds)` and adds one per
/// message. Persisting the last revision covers a clock that steps backwards;
/// seeding from the clock covers lost storage (a reinstall, deleted defaults).
/// Receivers can therefore compare revisions alone, and need no restart
/// heuristic. Values stay far below 2^53, so JavaScript reads them exactly.
public struct RevisionCounter: Equatable, Sendable {
    /// The last revision handed out, or the seed if none has been.
    public private(set) var current: UInt64

    public init(lastPersisted: UInt64?, now: Date = Date()) {
        let clock = UInt64(max(0, (now.timeIntervalSince1970 * 1000).rounded(.down)))
        current = max(lastPersisted ?? 0, clock)
    }

    /// Persist the result before sending it, so a crash can't reuse it.
    public mutating func next() -> UInt64 {
        current += 1
        return current
    }
}

/// Mints and ends `PlaybackMessage.listeningSessionID`.
///
/// A listening session opens when playback starts with none open, survives
/// track changes, pauses and one-off read errors, and closes on stop, on Music
/// quitting, or on a refused Automation permission. A Music restart therefore
/// always ends the session: Music comes back stopped with no current track.
public struct ListeningSessionTracker: Equatable, Sendable {
    public private(set) var current: UUID?

    public init(current: UUID? = nil) {
        self.current = current
    }

    /// Feed every observed state, in order. Returns the session for it.
    public mutating func update(for state: PlaybackState, makeID: () -> UUID = UUID.init) -> UUID? {
        if !state.continuesSession {
            current = nil
        } else if current == nil, state == .playing {
            current = makeID()
        }
        return current
    }
}
