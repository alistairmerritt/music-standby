import Foundation
import StandByProtocol

/// Holds back failed reads of Music for a short while, so a slow Music
/// doesn't flash "Can’t read Music right now" on the Mac or empty the phone's
/// player.
///
/// Seen on 20 November 2026: Music, starting a song from Apple Music outside
/// the library, took 6.3 s to answer, so several 3 s reads in a row timed out
/// (-1712). The Mac's menu showed the error and the phone showed no song, then
/// both recovered once Music caught up.
///
/// A failed read is held while the last good read had a song playing or
/// paused and the failures began less than `window` ago.
///
/// 30 s since 21 November 2026: a Music that had run for 8 days used a whole
/// CPU core and answered in 1–13 s, so 10 s wasn't enough. Quitting and
/// reopening Music fixed it; `MusicSnapshot.isMusicSlow` says so in the menu. Only `.error` is
/// held: a refused permission or Music quitting always goes through at once.
public struct ReadErrorHold: Sendable {
    public var window: TimeInterval
    private var firstFailure: Date?

    public init(window: TimeInterval = 30) {
        self.window = window
    }

    /// True when `read` should be dropped, so the last good read stays.
    public mutating func holds(_ read: MusicSnapshot, lastGood: MusicSnapshot?) -> Bool {
        guard read.state == .error else {
            firstFailure = nil
            return false
        }
        guard let lastGood, lastGood.track != nil, lastGood.state == .playing || lastGood.state == .paused else { return false }
        let first = firstFailure ?? read.capturedAt
        firstFailure = first
        return read.capturedAt.timeIntervalSince(first) < window
    }
}
