import Foundation

/// Apple Music on this phone, as Continue on iPhone uses it. The app's own is
/// `MPMusicPlayerController.systemMusicPlayer`; tests use a stand-in.
@MainActor
public protocol PhoneMusicPlaying: AnyObject {
    /// True once Second Chair may use Apple Music, asking the first time.
    func requestAccess() async -> Bool
    /// Replaces Apple Music's queue here with these catalogue IDs, starts the
    /// first at `position()` (read just before it plays, so the Mac's playing
    /// meanwhile counts), and returns true once Music is playing that song,
    /// or false after `timeout` seconds.
    func play(catalogIDs: [String], position: @escaping @MainActor () -> TimeInterval, timeout: TimeInterval) async -> Bool
}

public enum ContinueOutcome: Equatable, Sendable {
    /// Playing here; the Mac is paused (or already was).
    case continued
    /// The Mac's state has no catalogue ID: not paired with Music, or a song
    /// that isn't in the Mac's library.
    case unavailable
    /// Apple Music access was refused.
    case notAllowed
    /// Apple Music here didn't start the song. The Mac carries on.
    case didNotStart
    /// Playing here, but the Mac didn't pause.
    case macStillPlaying
}
