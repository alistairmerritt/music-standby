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
    /// What Apple Music here is on, or nil when nothing is loaded or it
    /// can't be read (before Apple Music access is allowed).
    func nowPlaying() -> PhoneNowPlaying?
    func pause()
}

/// Apple Music on this phone at one moment.
public struct PhoneNowPlaying: Equatable, Sendable {
    public var catalogID: String?
    public var position: TimeInterval
    public var isPlaying: Bool

    public init(catalogID: String?, position: TimeInterval, isPlaying: Bool) {
        self.catalogID = catalogID
        self.position = position
        self.isPlaying = isPlaying
    }
}

public enum SendBackOutcome: Equatable, Sendable {
    /// Playing on the Mac; Apple Music here is paused.
    case sentBack
    /// Apple Music here isn't playing a song with a catalogue ID.
    case nothingPlayingHere
    /// The song isn't the Mac's current song or in its Up Next.
    case notInMacQueue
    /// The Mac refused a step, or couldn't be reached. Apple Music here carries on.
    case macRefused
    /// The Mac didn't get to the song in time. Apple Music here carries on.
    case macDidNotStart
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
