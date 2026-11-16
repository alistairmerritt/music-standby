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
    /// Plays Apple Music's queue here on from where it is.
    func resume()
    /// Adds an Apple Music station made from this song (Music's own Create
    /// Station) after everything queued here, so the music doesn't stop
    /// when the queue does.
    func appendStation(seededBy catalogID: String) async -> StationAppend
    /// Apple Music catalogue songs like this one, for a song the Mac has no
    /// catalogue ID for. Empty when none, or Apple Music can't be asked.
    func searchCatalog(title: String, artist: String) async -> [CatalogCandidate]
}

/// One song from an Apple Music catalogue search.
public struct CatalogCandidate: Equatable, Sendable {
    public var id: String
    public var title: String
    public var artist: String
    public var duration: TimeInterval?

    public init(id: String, title: String, artist: String, duration: TimeInterval?) {
        self.id = id
        self.title = title
        self.artist = artist
        self.duration = duration
    }

    /// The candidate that is this song: the same title and lead artist,
    /// closest in length, and within `durationTolerance` when both lengths
    /// are known. Covers by other artists and other versions don't count.
    public static func best(title: String, artist: String, duration: TimeInterval, in candidates: [CatalogCandidate]) -> CatalogCandidate? {
        let wanted = fold(title)
        let lead = fold(artist.components(separatedBy: CharacterSet(charactersIn: ",&")).first ?? artist)
        func gap(_ c: CatalogCandidate) -> TimeInterval {
            guard let length = c.duration, duration > 0 else { return 0 }
            return abs(length - duration)
        }
        let matching = candidates.filter { fold($0.title) == wanted && fold($0.artist).contains(lead) && gap($0) <= durationTolerance }
        return matching.min { gap($0) < gap($1) }
    }

    public static let durationTolerance: TimeInterval = 5

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// What `appendStation(seededBy:)` managed (added 15 November 2026).
public enum StationAppend: Equatable, Sendable {
    /// Queued after the songs.
    case added
    /// Apple Music has no station for this song.
    case noStation
    /// The catalogue couldn't be asked, or the player refused it.
    case failed(String)
}

/// Apple Music on this phone at one moment.
public struct PhoneNowPlaying: Equatable, Sendable {
    public var catalogID: String?
    public var position: TimeInterval
    public var isPlaying: Bool
    /// For telling the song apart on the Mac before its catalogue ID is in.
    public var title: String?

    public init(catalogID: String?, position: TimeInterval, isPlaying: Bool, title: String? = nil) {
        self.catalogID = catalogID
        self.position = position
        self.isPlaying = isPlaying
        self.title = title
    }
}

public enum SendBackOutcome: Equatable, Sendable {
    /// Playing on the Mac; Apple Music here is paused.
    case sentBack
    /// Apple Music here has no song with a catalogue ID loaded.
    case nothingPlayingHere
    /// The song wasn't in the Mac's queue, so the Mac plays its station,
    /// which started with another song. Apple Music here is paused.
    case sentAsStation
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
    /// Nothing new on the Mac since the last Continue on iPhone (it's still
    /// paused where it stopped for this phone), so Apple Music here played on
    /// from where it is.
    case resumedHere
    /// As `resumedHere`, but Apple Music here was already playing.
    case alreadyPlayingHere
}
