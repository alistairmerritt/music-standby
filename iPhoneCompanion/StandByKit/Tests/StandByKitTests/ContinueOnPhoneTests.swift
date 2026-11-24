import Foundation
import Testing
@testable import StandByKit

@MainActor
final class FakePhoneMusic: PhoneMusicPlaying {
    var allowed = true
    var starts = true
    private(set) var asked: [(ids: [String], position: TimeInterval)] = []

    func requestAccess() async -> Bool { allowed }

    func play(catalogIDs: [String], position: @escaping @MainActor () -> TimeInterval, timeout: TimeInterval) async -> Bool {
        asked.append((catalogIDs, position()))
        return starts
    }

    var current: PhoneNowPlaying?
    private(set) var pauses = 0
    func nowPlaying() -> PhoneNowPlaying? { current }
    func pause() {
        pauses += 1
        current?.isPlaying = false
    }
    private(set) var resumes = 0
    func resume() {
        resumes += 1
        current?.isPlaying = true
    }
    var catalog: [CatalogCandidate] = []
    private(set) var searches: [String] = []
    func searchCatalog(title: String, artist: String) async -> [CatalogCandidate] {
        searches.append("\(title) \(artist)")
        return catalog
    }
    var station: StationAppend = .added
    private(set) var stationSeeds: [String] = []
    func appendStation(seededBy catalogID: String) async -> StationAppend {
        stationSeeds.append(catalogID)
        return station
    }
    /// What `playlistPlace` finds here, and the remembered places it was given.
    var playlistHere: PlaylistPlace?
    private(set) var remembered: [PlaylistPlace?] = []
    func playlistPlace(remembered place: PlaylistPlace?) async -> PlaylistPlace? {
        remembered.append(place)
        return playlistHere
    }
    /// What `albumPlace()` finds here, and how often it was asked.
    var albumHere: AlbumPlace?
    private(set) var albumAsks = 0
    private(set) var rememberedAlbums: [AlbumPlace?] = []
    func albumPlace(remembered place: AlbumPlace?) async -> AlbumPlace? {
        albumAsks += 1
        rememberedAlbums.append(place)
        return albumHere
    }
    /// What `play(_:in:…)` plays: nil when the playlist isn't here.
    var playsPlaylist: PlaylistPlace?
    private(set) var playlistAsked: [(id: String, place: PlaylistPlace, position: TimeInterval)] = []
    func play(_ catalogID: String, in place: PlaylistPlace, position: @escaping @MainActor () -> TimeInterval,
              timeout: TimeInterval) async -> PlaylistPlace? {
        playlistAsked.append((catalogID, place, position()))
        return playsPlaylist
    }

    // 17 November 2026
    var playsAlbum: AlbumPlace?
    private(set) var albumPlayAsked: [(id: String, place: AlbumPlace)] = []
    func play(_ catalogID: String, inAlbum place: AlbumPlace, position: @escaping @MainActor () -> TimeInterval,
              timeout: TimeInterval) async -> AlbumPlace? {
        albumPlayAsked.append((catalogID, place))
        return playsAlbum
    }
    var playsLibrary = false
    private(set) var libraryAsked: [String] = []
    func playShuffledLibrary(from catalogID: String, position: @escaping @MainActor () -> TimeInterval, timeout: TimeInterval) async -> Bool {
        libraryAsked.append(catalogID)
        return playsLibrary
    }
    var playsFromAppleMusic: AppleMusicSource?
    private(set) var appleMusicAsked: [(id: String, shuffled: Bool, allowStation: Bool, following: [String])] = []
    func playFromAppleMusic(_ catalogID: String, position: @escaping @MainActor () -> TimeInterval, timeout: TimeInterval,
                            shuffled: Bool, allowStation: Bool, following: [String]) async -> AppleMusicSource? {
        appleMusicAsked.append((catalogID, shuffled, allowStation, following))
        return playsFromAppleMusic
    }
    var appleMusicHere: AppleMusicSource?
    func appleMusicSource() async -> AppleMusicSource? { appleMusicHere }
    var adds = true
    private(set) var added: [AppleMusicSource] = []
    func addToLibrary(_ source: AppleMusicSource) async -> Bool {
        added.append(source)
        return adds
    }
    var shufflingLibrary = false
    func isShufflingLibrary() async -> Bool { shufflingLibrary }
    var repeatHere: RepeatMode?
    private(set) var repeatsSet: [RepeatMode] = []
    func repeatMode() -> RepeatMode? { repeatHere }
    func setRepeat(_ mode: RepeatMode) { repeatsSet.append(mode) }
}

private func continuable(state: PlaybackState = .playing, revision: UInt64 = 1) -> PlaybackMessage {
    var song = track()
    song.catalogID = "1102360418"
    var m = message(revision: revision, state: state, track: song)
    m.upNext = [QueuedTrack(catalogID: "1102359994", title: "Lady Divine", artist: "Alela Diane", duration: 312),
                QueuedTrack(catalogID: nil, title: "Uploaded demo", artist: "Me", duration: 90),
                QueuedTrack(catalogID: "1102359746", title: "Sleepers Beat Theme", artist: "Ben Lukas Boysen", duration: 277)]
    return m
}

@MainActor
@Suite struct ContinueOnPhoneTests {
    private func ready(_ m: PlaybackMessage = continuable()) async -> (Harness, Task<Void, Never>) {
        let h = Harness()
        let task = await h.run()
        await h.connected()
        await h.transport.emit(.playback(m))
        await eventually("the Mac's song seen") { h.model.canContinueOnPhone == (m.track != nil) && h.controller.isActive }
        return (h, task)
    }

    @Test func startsTheSongAndUpNextHereAtTheMacsPositionThenPausesTheMac() async {
        let (h, task) = await ready()
        defer { task.cancel() }
        h.clock.advance(42)   // 42 s into the song since the Mac's last state
        let phone = FakePhoneMusic()
        #expect(await h.model.continueOnPhone(with: phone) == .continued)
        #expect(phone.asked.first?.ids == ["1102360418", "1102359994", "1102359746"], "songs without a catalogue ID are skipped")
        #expect(phone.asked.first?.position == 42)
        #expect(await h.transport.sent.map(\.kind) == [.pause])
    }

    // MARK: Without the Mac (25 November 2026: a laptop asleep in a bag on the drive to work)

    private func away(_ h: Harness, _ away: MacAway) async {
        await h.transport.emit(.connection(.macOffline(macName: "Studio Mac", away: away)))
        await eventually("the Mac away") { h.model.connection == .macOffline(macName: "Studio Mac", away: away) }
    }

    @Test func withTheMacAsleepItsLastSongPlaysHereAndTheMacIsLeftAlone() async {
        let (h, task) = await ready(continuable(state: .paused))
        defer { task.cancel() }
        await away(h, .asleep)
        let phone = FakePhoneMusic()
        #expect(await h.model.continueOnPhone(with: phone) == .continuedWithoutMac(.asleep))
        #expect(phone.asked.first?.ids == ["1102360418", "1102359994", "1102359746"])
        #expect(phone.asked.first?.position == 0, "paused at the start of the song in the test's state")
        #expect(await h.transport.sent.isEmpty, "nothing sent to a Mac that isn't there")
        #expect(HandoverMemory.defaults(h.defaults).load()?.catalogID == "1102360418", "kept for the way back")
    }

    @Test func aMacGoneWhilePlayingLongAgoStartsTheSongFromTheTop() async {
        let (h, task) = await ready()
        defer { task.cancel() }
        await away(h, .lost)
        h.clock.advance(7200)   // two hours of a "playing" state that nothing updated
        let phone = FakePhoneMusic()
        #expect(await h.model.continueOnPhone(with: phone) == .continuedWithoutMac(.lost))
        #expect(phone.asked.first?.position == 0)
    }

    @Test func withoutTheMacAppleMusicsHistoryIsntSearched() async {
        var m = continuable(state: .paused)
        m.fromAppleMusic = true
        let (h, task) = await ready(m)
        defer { task.cancel() }
        await away(h, .asleep)
        let phone = FakePhoneMusic()
        #expect(await h.model.continueOnPhone(with: phone) == .continuedWithoutMac(.asleep))
        #expect(phone.asked.first?.ids.first == "1102360418", "straight to the song and the Mac's Up Next")
    }

    @Test func outOfTimeTheStationToFollowIsLeftOut() async {
        let (h, task) = await ready()
        defer { task.cancel() }
        let phone = FakePhoneMusic()
        #expect(await h.model.continueOnPhone(with: phone, within: 0.001) == .continued)
        #expect(phone.stationSeeds.isEmpty, "only adds to what plays later, so dropped when time is short")
        #expect(phone.asked.count == 1, "the song itself still played")
    }

    @Test func theWithoutMacMessageNamesTheSongAndWhy() {
        #expect(ContinueOutcome.withoutMacMessage(.asleep, title: "Low Sun") == "Your Mac is asleep, so “Low Sun” is playing here from where it stopped.")
        #expect(ContinueOutcome.withoutMacMessage(.lost, title: nil) == "Your Mac isn’t connected, so your Mac’s song is playing here from where it last was.")
    }

    @Test func anUnknownAwayReasonReadsAsLost() throws {
        let json = #"{"mac":{"id":"m","name":"Mac"},"macConnected":false,"macAway":"hibernating"}"#
        let state = try StandByWire.makeDecoder().decode(SessionState.self, from: Data(json.utf8))
        #expect(state.macAway == .lost)
        let old = #"{"mac":{"id":"m","name":"Mac"},"macConnected":false}"#
        #expect(try StandByWire.makeDecoder().decode(SessionState.self, from: Data(old.utf8)).macAway == nil)
    }

    @Test func leavesTheMacPlayingWhenAppleMusicDoesntStart() async {
        let (h, task) = await ready()
        defer { task.cancel() }
        let phone = FakePhoneMusic()
        phone.starts = false
        #expect(await h.model.continueOnPhone(with: phone) == .didNotStart)
        #expect(await h.transport.sent.isEmpty)
    }

    @Test func asksForNothingWithoutAccessOrACatalogueID() async {
        let (h, task) = await ready()
        defer { task.cancel() }
        let refused = FakePhoneMusic()
        refused.allowed = false
        #expect(await h.model.continueOnPhone(with: refused) == .notAllowed)
        #expect(refused.asked.isEmpty)

        // No catalogue ID from the Mac, and none in the catalogue here either.
        let (plain, plainTask) = await ready(message())
        defer { plainTask.cancel() }
        #expect(plain.model.canContinueOnPhone, "offered: the phone looks it up")
        #expect(plain.model.macSongHasNoCatalogID)
        let phone = FakePhoneMusic()
        #expect(await plain.model.continueOnPhone(with: phone) == .unavailable)
        #expect(phone.searches == ["Song Artist"], "looked up here first")
        #expect(phone.asked.isEmpty)
        #expect(await plain.transport.sent.isEmpty)
    }

    /// The Mac couldn't find Daniel Caesar's "Japanese Denim" in Apple's
    /// public search, which has only covers of it; the phone's Apple Music
    /// catalogue has it (16 November 2026).
    @Test func aSongTheMacCouldntFindIsLookedUpHere() async {
        let (h, task) = await ready(message(state: .playing))   // "Song" by "Artist", 200 s, no catalogue ID
        defer { task.cancel() }
        let phone = FakePhoneMusic()
        phone.catalog = [
            CatalogCandidate(id: "111", title: "Song", artist: "Someone Covering It", duration: 200),
            CatalogCandidate(id: "222", title: "Song (Instrumental)", artist: "Artist", duration: 200),
            CatalogCandidate(id: "333", title: "Song", artist: "Artist", duration: 201),
        ]
        #expect(await h.model.continueOnPhone(with: phone) == .continued)
        #expect(phone.asked.first?.ids.first == "333", "the artist's own, not a cover or another version")
        #expect(await h.transport.sent.map(\.kind) == [.pause])
    }

    @Test func tellsAPausedMacTooSoItOffersContinueFromIPhone() async {
        let (h, task) = await ready(continuable(state: .paused))
        defer { task.cancel() }
        h.clock.advance(42)
        let phone = FakePhoneMusic()
        #expect(await h.model.continueOnPhone(with: phone) == .continued)
        #expect(phone.asked.first?.position == 0, "a paused Mac's position doesn't run on")
        // Without this, a Mac paused before Continue on iPhone never offered
        // Continue from iPhone (seen 12 Nov 2026). Music ignores the pause.
        let sent = await h.transport.sent
        #expect(sent.map(\.kind) == [.pause])
        #expect(sent.first?.reason == .continueOnPhone)
    }
}

@MainActor
@Suite struct SendBackToMacTests {
    /// The Mac paused after a Continue on iPhone, on the song it handed over.
    private func handedOver() async -> (Harness, Task<Void, Never>) {
        let h = Harness()
        let task = await h.run()
        await h.connected()
        await h.transport.emit(.playback(continuable(state: .paused)))
        await eventually("Mac state seen") { h.model.macQueuePosition(of: "1102360418") == 0 }
        return (h, task)
    }

    @Test func skipsTheMacAheadToThePhonesSongSeeksPlaysThenPausesThePhone() async {
        let (h, task) = await handedOver()
        defer { task.cancel() }
        let phone = FakePhoneMusic()
        phone.current = PhoneNowPlaying(catalogID: "1102359746", position: 42, isPlaying: true)   // three songs on
        #expect(h.model.macQueuePosition(of: "1102359746") == 3, "the uploaded demo has no ID but still holds its place")
        let sending = Task { await h.model.sendBackToMac(with: phone) }
        await eventually("play sent") { await h.transport.sent.count == 5 }
        #expect(phone.pauses == 0, "nothing pauses here before the Mac plays")
        var playing = continuable(state: .playing, revision: 2)
        playing.track?.catalogID = "1102359746"
        await h.transport.emit(.playback(playing))
        await eventually("Mac playing seen") { h.model.macQueuePosition(of: "1102359746") == 0 }
        h.sleeper.releaseAll()
        #expect(await sending.value == .sentBack)
        let sent = await h.transport.sent
        #expect(sent.map(\.kind) == [.next, .next, .next, .seek, .play])
        #expect(sent[3].position == 42.3)
        #expect(phone.pauses == 1)
    }

    @Test func aSlowReplyIsntARefusalWhenTheMacPlaysAnyway() async {
        let (h, task) = await handedOver()
        defer { task.cancel() }
        await h.transport.leaveUnanswered([.play])   // the relay's 1.2 s passed; Music played regardless
        let phone = FakePhoneMusic()
        phone.current = PhoneNowPlaying(catalogID: "1102360418", position: 50, isPlaying: true)
        let sending = Task { await h.model.sendBackToMac(with: phone) }
        await eventually("seek and play sent") { await h.transport.sent.map(\.kind) == [.seek, .play] }
        var playing = continuable(state: .playing, revision: 2)
        playing.elapsedTime = 50
        await h.transport.emit(.playback(playing))
        await eventually("Mac playing seen") { h.model.attributes?.isPlaying == true }
        h.sleeper.releaseAll()
        #expect(await sending.value == .sentBack)
        #expect(phone.pauses == 1)
    }

    @Test func aRealRefusalStopsAtOnceAndLeavesThePhoneAlone() async {
        let (h, task) = await handedOver()
        defer { task.cancel() }
        await h.transport.refuse([.seek])
        let phone = FakePhoneMusic()
        phone.current = PhoneNowPlaying(catalogID: "1102359994", position: 10, isPlaying: true)
        #expect(await h.model.sendBackToMac(with: phone) == .macRefused)
        #expect(await h.transport.sent.map(\.kind) == [.next, .seek], "nothing after the refusal")
        #expect(phone.pauses == 0)
    }

    @Test func doesntPauseAPhoneHeadphonesAlreadyPaused() async {
        let (h, task) = await handedOver()
        defer { task.cancel() }
        let phone = FakePhoneMusic()
        phone.current = PhoneNowPlaying(catalogID: "1102360418", position: 50, isPlaying: true)
        let sending = Task { await h.model.sendBackToMac(with: phone) }
        await eventually("play sent") { await h.transport.sent.map(\.kind) == [.seek, .play] }
        phone.current?.isPlaying = false   // AirPods moved to the Mac and paused it here
        await h.transport.emit(.playback(continuable(state: .playing, revision: 2)))
        await eventually("Mac playing seen") { h.model.attributes?.isPlaying == true }
        h.sleeper.releaseAll()
        #expect(await sending.value == .sentBack)
        #expect(phone.pauses == 0)
    }

    @Test func sendsNothingForASongWithoutACatalogueID() async {
        let (h, task) = await handedOver()
        defer { task.cancel() }
        let phone = FakePhoneMusic()
        phone.current = PhoneNowPlaying(catalogID: nil, position: 10, isPlaying: false)
        #expect(await h.model.sendBackToMac(with: phone) == .nothingPlayingHere)
        #expect(await h.transport.sent.isEmpty)
    }

    @Test func continuesOnTheMacFromAPausedPhoneToo() async {
        let (h, task) = await handedOver()
        defer { task.cancel() }
        let phone = FakePhoneMusic()
        phone.current = PhoneNowPlaying(catalogID: "1102359994", position: 64, isPlaying: false)   // paused here, one song on
        let sending = Task { await h.model.sendBackToMac(with: phone) }
        await eventually("next, seek and play sent") { await h.transport.sent.map(\.kind) == [.next, .seek, .play] }
        var playing = continuable(state: .playing, revision: 2)
        playing.track?.catalogID = "1102359994"
        await h.transport.emit(.playback(playing))
        await eventually("Mac playing seen") { h.model.attributes?.isPlaying == true }
        h.sleeper.releaseAll()
        #expect(await sending.value == .sentBack)
        #expect(await h.transport.sent[1].position == 64.3, "from the phone's paused point")
        #expect(phone.pauses == 0, "already paused here")
    }

    @Test func keepsThePhonePlayingWhenTheMacDoesntStart() async {
        let (h, task) = await handedOver()
        defer { task.cancel() }
        let phone = FakePhoneMusic()
        phone.current = PhoneNowPlaying(catalogID: "1102360418", position: 100, isPlaying: true)   // the Mac's own song
        let sending = Task { await h.model.sendBackToMac(with: phone, timeout: 5) }
        await eventually("seek and play sent") { await h.transport.sent.map(\.kind) == [.seek, .play] }
        await eventually("waiting") { h.sleeper.pending == 1 }
        h.clock.advance(6)
        h.sleeper.releaseAll()
        #expect(await sending.value == .macDidNotStart)
        #expect(phone.pauses == 0)
    }
}

@Suite struct CatalogCandidateTests {
    @Test func theArtistsOwnSongOfAboutTheSameLength() {
        let songs = [
            CatalogCandidate(id: "cover", title: "Japanese Denim", artist: "Rachel Bobbitt & Justice Der", duration: 369),
            CatalogCandidate(id: "piano", title: "Japanese Denim (Piano Arrangement)", artist: "The Theorist", duration: 264),
            CatalogCandidate(id: "live", title: "Japanese Denim", artist: "Daniel Caesar", duration: 300),
            CatalogCandidate(id: "own", title: "Japanese Denim", artist: "Daniel Caesar", duration: 270.5),
        ]
        #expect(CatalogCandidate.best(title: "Japanese Denim", artist: "Daniel Caesar", duration: 270.6, in: songs)?.id == "own")
        #expect(CatalogCandidate.best(title: "japanese denim", artist: "Daniel Caesar & Someone", duration: 271, in: songs)?.id == "own",
                "case and a featured artist don't matter")
        #expect(CatalogCandidate.best(title: "Japanese Denim", artist: "Daniel Caesar", duration: 100, in: songs) == nil, "too far off in length")
        #expect(CatalogCandidate.best(title: "Japanese Denim", artist: "Nobody", duration: 270, in: songs) == nil)
    }
}

@Suite struct DidNotStartMessageTests {
    @Test func saysWhatThePhoneIsStillPlaying() {
        let here = PhoneNowPlaying(catalogID: "1", position: 30, isPlaying: true, title: "Song A")
        #expect(ContinueOutcome.didNotStartMessage(here: here)
                == "Apple Music on your iPhone didn’t switch to this song, so it’s still playing “Song A”. Nothing changed on your Mac.")
    }

    @Test func playingWithNoTitle() {
        let here = PhoneNowPlaying(catalogID: nil, position: 0, isPlaying: true)
        #expect(ContinueOutcome.didNotStartMessage(here: here).contains("still playing its own music."))
    }

    @Test func silentOrPausedPhone() {
        let expected = "Apple Music on your iPhone didn’t start this song. Nothing changed on your Mac."
        #expect(ContinueOutcome.didNotStartMessage(here: nil) == expected)
        #expect(ContinueOutcome.didNotStartMessage(here: PhoneNowPlaying(catalogID: "1", position: 0, isPlaying: false, title: "Song A")) == expected)
    }
}
