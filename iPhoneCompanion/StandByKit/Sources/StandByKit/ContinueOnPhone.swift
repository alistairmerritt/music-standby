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
    /// The library playlist Apple Music here plays its current song from,
    /// and the song's place in it, for Continue on Mac: a playlist Apple
    /// Music lists as recently played, or else `remembered` (the one
    /// Continue on iPhone last started here), that has the song, at the
    /// place Music's queue says unless shuffling; or else, unshuffled, the
    /// library playlist with the song at that place, as recently played
    /// lags a playlist started here by about a minute. Nil when it can't be
    /// told.
    func playlistPlace(remembered: PlaylistPlace?) async -> PlaylistPlace?
    /// Plays a library playlist here like `place` from the song
    /// `catalogID`: the one with that name (Apple Music's ID first, then
    /// the same size first) that has the song, at `place.index` or else the
    /// closest place, from `position()`. Returns the place it played, with
    /// this phone's ID for the playlist, once Music plays the song; nil when
    /// no playlist here has it or Music didn't start it in `timeout`.
    func play(_ catalogID: String, in place: PlaylistPlace, position: @escaping @MainActor () -> TimeInterval,
              timeout: TimeInterval) async -> PlaylistPlace?
    /// The library album Apple Music here plays its current song from, and
    /// the song's place in it by disc, then track: for Continue on Mac when
    /// the song isn't from a playlist. Shuffled, it's accepted when it's
    /// `remembered` (the album Continue on iPhone last started here; Apple
    /// Music never lists one an app queued) or the album recently played
    /// names. Nil when it can't be told.
    func albumPlace(remembered: AlbumPlace?) async -> AlbumPlace?

    // MARK: Added 17 November 2026

    /// Plays this library song's album here from the song (the one nearest
    /// `place.index` when the album has it twice), shuffled after the song
    /// starts if `place` is. Returns the place it played once Music plays the
    /// song; nil when the library here hasn't the song or it didn't start.
    func play(_ catalogID: String, inAlbum place: AlbumPlace, position: @escaping @MainActor () -> TimeInterval,
              timeout: TimeInterval) async -> AlbumPlace?
    /// Plays this library song with the whole library after it, shuffled once
    /// the song plays. False when the library here hasn't the song.
    func playShuffledLibrary(from catalogID: String, position: @escaping @MainActor () -> TimeInterval, timeout: TimeInterval) async -> Bool
    /// Plays the song from the Apple Music playlist or album that Apple
    /// Music's recently played lists and that has it, or, with
    /// `allowStation`, the song followed by the station listed last. For a
    /// Mac playing from outside its library (`fromAppleMusic`). Returns what
    /// it played; nil when recently played has nothing with the song yet
    /// (it lags about a minute) or Music didn't start it.
    /// `following` is what the Mac queues after the song: a playlist or
    /// album only counts when its songs match (`ContainerMatch`).
    func playFromAppleMusic(_ catalogID: String, position: @escaping @MainActor () -> TimeInterval, timeout: TimeInterval,
                            shuffled: Bool, allowStation: Bool, following: [String]) async -> AppleMusicSource?
    /// Where Apple Music here plays its current song from when it's not a
    /// library playlist or album: an Apple Music playlist or album that
    /// recently played lists and has the song, or the station listed last.
    func appleMusicSource() async -> AppleMusicSource?
    /// Adds an Apple Music playlist or album to the library, so a Mac can
    /// play it. True once added.
    func addToLibrary(_ source: AppleMusicSource) async -> Bool
    /// A guess, as iOS doesn't say: Apple Music here shuffles a song from the
    /// library, and it isn't from a playlist or album found already.
    func isShufflingLibrary() async -> Bool
    /// Apple Music's repeat here; nil when it follows the Music app's own.
    func repeatMode() -> RepeatMode?
    func setRepeat(_ mode: RepeatMode)
}

/// What Apple Music here plays from outside the library (17 November 2026).
public enum AppleMusicSource: Equatable, Sendable {
    /// `cloudID` is Apple Music's ID for it.
    case playlist(PlaylistPlace)
    case album(AlbumPlace, id: String)
    case station(StationPlace)
}

extension PhoneMusicPlaying {
    public func play(_ catalogID: String, inAlbum place: AlbumPlace, position: @escaping @MainActor () -> TimeInterval,
                     timeout: TimeInterval) async -> AlbumPlace? { nil }
    public func playShuffledLibrary(from catalogID: String, position: @escaping @MainActor () -> TimeInterval,
                                    timeout: TimeInterval) async -> Bool { false }
    public func playFromAppleMusic(_ catalogID: String, position: @escaping @MainActor () -> TimeInterval, timeout: TimeInterval,
                                   shuffled: Bool, allowStation: Bool, following: [String]) async -> AppleMusicSource? { nil }
    public func appleMusicSource() async -> AppleMusicSource? { nil }
    public func addToLibrary(_ source: AppleMusicSource) async -> Bool { false }
    public func isShufflingLibrary() async -> Bool { false }
    public func repeatMode() -> RepeatMode? { nil }
    public func setRepeat(_ mode: RepeatMode) {}
    public func albumPlace(remembered: AlbumPlace?) async -> AlbumPlace? { nil }
    public func playlistPlace(remembered: PlaylistPlace?) async -> PlaylistPlace? { nil }
    public func play(_ catalogID: String, in place: PlaylistPlace, position: @escaping @MainActor () -> TimeInterval,
                     timeout: TimeInterval) async -> PlaylistPlace? { nil }
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

    public static func fold(_ text: String) -> String {
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
    /// The Mac wasn't connected (asleep, closed, or gone), so the Mac's last
    /// song plays here from where it stopped, and the Mac wasn't asked to
    /// pause (25 November 2026: a laptop in a bag on the drive to work).
    case continuedWithoutMac(MacAway)
}

extension ContinueOutcome {
    /// What to say when the song plays here without the Mac (25 November 2026).
    public static func withoutMacMessage(_ away: MacAway, title: String?) -> String {
        let song = title.map { "“\($0)”" } ?? "your Mac’s song"
        return switch away {
        case .asleep: "Your Mac is asleep, so \(song) is playing here from where it stopped."
        case .quit: "Second Chair isn’t open on your Mac, so \(song) is playing here from where it last was."
        case .lost: "Your Mac isn’t connected, so \(song) is playing here from where it last was."
        }
    }

    /// What to say when Apple Music here didn't start the Mac's song, given
    /// what it's playing now. "Couldn't start playback on your iPhone. Music
    /// is still playing on your Mac." read as if the phone were silent when
    /// it was playing another song, and the Mac may have been paused
    /// (23 November 2026). The Mac is never touched until the song plays
    /// here, so it's as it was either way.
    public static func didNotStartMessage(here: PhoneNowPlaying?) -> String {
        guard let here, here.isPlaying else {
            return "Apple Music on your iPhone didn’t start this song. Nothing changed on your Mac."
        }
        let playing = here.title.map { "“\($0)”" } ?? "its own music"
        return "Apple Music on your iPhone didn’t switch to this song, so it’s still playing \(playing). Nothing changed on your Mac."
    }
}
