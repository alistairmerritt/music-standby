import Foundation
import Testing
@testable import StandByKit

/// Hand-overs that carry a library playlist itself (17 November 2026).
private let aa = PlaylistPlace(name: "Road Trip", count: 123, index: 39)
private let aaHere = PlaylistPlace(name: "Road Trip", cloudID: "pl.u-Zx9yW8vU7tS6r", count: 123, index: 39)

private func playingFromAA(at place: PlaylistPlace = aa, state: PlaybackState = .playing) -> PlaybackMessage {
    var song = track()
    song.catalogID = "1102360418"
    var m = message(state: state, track: song)
    m.upNext = [QueuedTrack(catalogID: "1102359994", title: "Lady Divine", artist: "Alela Diane", duration: 312),
                QueuedTrack(catalogID: "1102359746", title: "Sleepers Beat Theme", artist: "Ben Lukas Boysen", duration: 277),
                QueuedTrack(catalogID: "1102359555", title: "Third", artist: "Artist", duration: 200),
                QueuedTrack(catalogID: "1102359444", title: "Fourth", artist: "Artist", duration: 200)]
    m.playlist = place
    return m
}

@MainActor
@Suite struct ContinueOnIPhoneWithAPlaylistTests {
    private func ready(_ m: PlaybackMessage) async -> (Harness, Task<Void, Never>) {
        let h = Harness()
        let task = await h.run()
        await h.connected()
        await h.transport.emit(.playback(m))
        await eventually("the Mac's song seen") { h.model.canContinueOnPhone && h.controller.isActive }
        return (h, task)
    }

    @Test func playsTheMacsPlaylistItselfAndRemembersIt() async {
        let (h, task) = await ready(playingFromAA())
        defer { task.cancel() }
        h.clock.advance(42)
        let phone = FakePhoneMusic()
        phone.playsPlaylist = aaHere
        #expect(await h.model.continueOnPhone(with: phone) == .continued)
        #expect(phone.playlistAsked.first?.id == "1102360418")
        #expect(phone.playlistAsked.first?.place == aa)
        #expect(phone.playlistAsked.first?.position == 42)
        #expect(phone.asked.isEmpty, "the playlist, not the Mac's next songs")
        #expect(await h.transport.sent.map(\.kind) == [.pause])
        #expect(HandoverMemory.defaults(h.defaults).loadPlaylist() == aaHere, "kept for the way back")
        #expect(phone.stationSeeds.isEmpty, "83 songs still to come")
    }

    /// Home's animation lands when the music moves, not when the hand-over
    /// has finished pausing the Mac and adding a station (23 November 2026).
    @Test func arrivalComesOnceTheSongPlaysHereAndBeforeTheMacPauses() async {
        let (h, task) = await ready(playingFromAA())
        defer { task.cancel() }
        let phone = FakePhoneMusic()
        phone.playsPlaylist = aaHere
        var arrivals = 0
        var playedWhenArrived = false
        let outcome = await h.model.continueOnPhone(with: phone) {
            arrivals += 1
            playedWhenArrived = !phone.playlistAsked.isEmpty
        }
        #expect(outcome == .continued)
        #expect(arrivals == 1)
        #expect(playedWhenArrived)
    }

    /// Every hand-over goes in the Lock Screen Record with where it came from
    /// (23 November 2026).
    @Test func aHandOverIsRecordedWithItsSource() async {
        let (h, task) = await ready(playingFromAA())
        defer { task.cancel() }
        let phone = FakePhoneMusic()
        phone.playsPlaylist = aaHere
        #expect(await h.model.continueOnPhone(with: phone, from: .shortcuts) == .continued)
        let recent = LockScreenRecord.entries(in: WidgetSnapshot.defaults).prefix(20).map(\.message)
        #expect(recent.contains { $0.hasPrefix("Continue on iPhone from Shortcuts: continued in ") })
    }

    @Test func noArrivalWhenTheSongDoesntStartHere() async {
        let (h, task) = await ready(playingFromAA())
        defer { task.cancel() }
        let phone = FakePhoneMusic()
        phone.starts = false
        var arrivals = 0
        let outcome = await h.model.continueOnPhone(with: phone) { arrivals += 1 }
        #expect(outcome == .didNotStart)
        #expect(arrivals == 0)
        #expect(await h.transport.sent.isEmpty, "the Mac plays on")
    }

    @Test func theMacsNextSongsWhenThePlaylistIsntHere() async {
        let (h, task) = await ready(playingFromAA())
        defer { task.cancel() }
        HandoverMemory.defaults(h.defaults).savePlaylist(aaHere)
        let phone = FakePhoneMusic()
        #expect(await h.model.continueOnPhone(with: phone) == .continued)
        #expect(phone.playlistAsked.count == 1)
        #expect(phone.asked.first?.ids == ["1102360418", "1102359994", "1102359746", "1102359555", "1102359444"])
        #expect(HandoverMemory.defaults(h.defaults).loadPlaylist() == nil, "an old playlist isn't kept")
        #expect(HandoverMemory.defaults(h.defaults).loadQueued() == phone.asked.first?.ids, "the queued songs are kept for the way back")
    }

    @Test func playingTheMacsPlaylistForgetsTheQueuedSongs() async {
        let (h, task) = await ready(playingFromAA())
        defer { task.cancel() }
        HandoverMemory.defaults(h.defaults).saveQueued(["1"])
        let phone = FakePhoneMusic()
        phone.playsPlaylist = aaHere
        #expect(await h.model.continueOnPhone(with: phone) == .continued)
        #expect(HandoverMemory.defaults(h.defaults).loadQueued() == nil)
    }

    @Test func aStationFollowsThePlaylistsLastSongs() async {
        let nearTheEnd = PlaylistPlace(name: "Road Trip", count: 123, index: 121)
        let (h, task) = await ready(playingFromAA(at: nearTheEnd))
        defer { task.cancel() }
        let phone = FakePhoneMusic()
        phone.playsPlaylist = nearTheEnd
        #expect(await h.model.continueOnPhone(with: phone) == .continued)
        #expect(phone.stationSeeds == ["1102360418"], "one song left, then the song's station")
    }

    @Test func anUnusablePlaceIsIgnored() async {
        let (h, task) = await ready(playingFromAA(at: PlaylistPlace(name: "Road Trip", count: 3, index: 9)))
        defer { task.cancel() }
        let phone = FakePhoneMusic()
        phone.playsPlaylist = aaHere
        #expect(await h.model.continueOnPhone(with: phone) == .continued)
        #expect(phone.playlistAsked.isEmpty)
        #expect(phone.asked.count == 1)
    }

    // MARK: Shuffled, albums, the library, Apple Music, repeat (17 November 2026)

    @Test func aShuffledPlaylistPlaysShuffledHereWithTheMacsRepeat() async {
        let shuffled = PlaylistPlace(name: "Road Trip", count: 123, index: 121, shuffled: true)
        var m = playingFromAA(at: shuffled)
        m.repeatMode = .all
        let (h, task) = await ready(m)
        defer { task.cancel() }
        let phone = FakePhoneMusic()
        phone.playsPlaylist = shuffled
        #expect(await h.model.continueOnPhone(with: phone) == .continued)
        #expect(phone.playlistAsked.first?.place == shuffled)
        #expect(phone.asked.isEmpty)
        #expect(phone.stationSeeds.isEmpty, "shuffled, the whole playlist is still to come")
        #expect(phone.repeatsSet == [.all])
    }

    @Test func theAlbumContinueOnIPhoneStartedIsRemembered() async throws {
        let album = AlbumPlace(title: "Made-Up Album", artist: "Made-Up Band", count: 10, index: 2, shuffled: true)
        var m = playingFromAA()
        m.playlist = nil
        m.album = album
        let (h, task) = await ready(m)
        defer { task.cancel() }
        let phone = FakePhoneMusic()
        phone.playsAlbum = album
        #expect(await h.model.continueOnPhone(with: phone) == .continued)
        #expect(HandoverMemory.defaults(h.defaults).loadAlbum() == album, "kept for the way back")
        // Anything else Continue on iPhone does forgets it.
        let (h2, task2) = await ready(playingFromAA())
        defer { task2.cancel() }
        HandoverMemory.defaults(h2.defaults).saveAlbum(album)
        let other = FakePhoneMusic()
        other.playsPlaylist = aaHere
        #expect(await h2.model.continueOnPhone(with: other) == .continued)
        #expect(HandoverMemory.defaults(h2.defaults).loadAlbum() == nil)
    }

    @Test func theMacsAlbumPlaysHere() async {
        let album = AlbumPlace(title: "Made-Up Album", artist: "Made-Up Band", count: 10, index: 2)
        var m = playingFromAA()
        m.playlist = nil
        m.album = album
        let (h, task) = await ready(m)
        defer { task.cancel() }
        let phone = FakePhoneMusic()
        phone.playsAlbum = album
        #expect(await h.model.continueOnPhone(with: phone) == .continued)
        #expect(phone.albumPlayAsked.map(\.id) == ["1102360418"])
        #expect(phone.asked.isEmpty && phone.playlistAsked.isEmpty)
        #expect(phone.repeatsSet.isEmpty, "the Mac sent no repeat")
        // Not here: the Mac's next songs.
        let (h2, task2) = await ready(m)
        defer { task2.cancel() }
        let missing = FakePhoneMusic()
        #expect(await h2.model.continueOnPhone(with: missing) == .continued)
        #expect(missing.asked.count == 1)
    }

    @Test func theMacsLibraryShuffledPlaysTheSongThenTheLibraryHere() async {
        var m = playingFromAA()
        m.playlist = nil
        m.shuffledLibrary = true
        let (h, task) = await ready(m)
        defer { task.cancel() }
        let phone = FakePhoneMusic()
        phone.playsLibrary = true
        #expect(await h.model.continueOnPhone(with: phone) == .continued)
        #expect(phone.libraryAsked == ["1102360418"])
        #expect(phone.asked.isEmpty)
        #expect(phone.stationSeeds.isEmpty)
    }

    @Test func appleMusicOnTheMacIsLookedUpInRecentlyPlayed() async {
        var m = playingFromAA()
        m.playlist = nil
        m.fromAppleMusic = true
        m.shuffled = true
        let (h, task) = await ready(m)
        defer { task.cancel() }
        let phone = FakePhoneMusic()
        phone.playsFromAppleMusic = .playlist(PlaylistPlace(name: "Today", cloudID: "pl.f4d106fed2bd", count: 50, index: 5, shuffled: true))
        #expect(await h.model.continueOnPhone(with: phone) == .continued)
        #expect(phone.appleMusicAsked.count == 1)
        #expect(phone.appleMusicAsked.first?.shuffled == true)
        #expect(phone.appleMusicAsked.first?.allowStation == false, "four songs ahead on the Mac: not a station")
        #expect(phone.appleMusicAsked.first?.following == m.upNext,
                "the Mac's next songs go along, so an album that merely has the song isn't taken for the playlist")
        #expect(phone.appleMusicAsked.first?.title == "Song", "and the song's title, for a playlist that lists it under another ID")
        #expect(phone.asked.isEmpty)
    }

    /// 25 November 2026: a Mac playing an Apple Music playlist had catalogue
    /// IDs for only the songs in its library, 9 of its 18 next songs, and the
    /// phone queued just those 9 when recently played didn't list the playlist.
    @Test func theMacsNextSongsWithoutCatalogueIDsAreFoundHere() async {
        var m = message(state: .playing)   // "Song" by "Artist", 200 s, no catalogue ID: outside the Mac's library
        m.fromAppleMusic = true
        m.upNext = [QueuedTrack(catalogID: nil, title: "Outside One", artist: "Band", duration: 200),
                    QueuedTrack(catalogID: "1102359994", title: "Lady Divine", artist: "Alela Diane", duration: 312),
                    QueuedTrack(catalogID: nil, title: "Outside Two", artist: "Band & Friend", duration: 180),
                    QueuedTrack(catalogID: nil, title: "Nowhere", artist: "Band", duration: 150)]
        let (h, task) = await ready(m)
        defer { task.cancel() }
        let phone = FakePhoneMusic()
        phone.catalog = [CatalogCandidate(id: "777", title: "Song", artist: "Artist", duration: 200),
                         CatalogCandidate(id: "901", title: "Outside One", artist: "Band", duration: 200),
                         CatalogCandidate(id: "902", title: "Outside Two", artist: "Band & Friend", duration: 181)]
        #expect(await h.model.continueOnPhone(with: phone) == .continued)
        #expect(phone.appleMusicAsked.first?.id == "777", "recently played is tried first")
        #expect(phone.asked.first?.ids == ["777", "901", "1102359994", "902"],
                "in the Mac's order, with what the phone found; one it can't find is left out")
        #expect(Set(phone.searches) == ["Song Artist", "Outside One Band", "Outside Two Band & Friend", "Nowhere Band"])
    }

    @Test func aStationOnTheMacFollowsTheSongHereAndRecentlyPlayedLaggingFallsBack() async {
        var m = playingFromAA()
        m.playlist = nil
        m.fromAppleMusic = true
        m.upNext = Array(m.upNext!.prefix(1))   // a station lists one song ahead
        let (h, task) = await ready(m)
        defer { task.cancel() }
        let phone = FakePhoneMusic()
        phone.playsFromAppleMusic = .station(StationPlace(id: "ra.985484166", name: "Made-Up Radio"))
        #expect(await h.model.continueOnPhone(with: phone) == .continued)
        #expect(phone.appleMusicAsked.first?.allowStation == true)
        #expect(phone.stationSeeds.isEmpty, "the Mac's station follows, not the song's")

        // Started on the Mac under a minute ago: recently played may still name the one before.
        var fresh = m
        fresh.appleMusicSince = Date().addingTimeInterval(-10)
        let (h3, task3) = await ready(fresh)
        defer { task3.cancel() }
        let early = FakePhoneMusic()
        early.playsFromAppleMusic = .station(StationPlace(id: "ra.985484166", name: "Made-Up Radio"))
        _ = await h3.model.continueOnPhone(with: early)
        #expect(early.appleMusicAsked.first?.allowStation == false)

        let (h2, task2) = await ready(m)
        defer { task2.cancel() }
        let lagging = FakePhoneMusic()
        #expect(await h2.model.continueOnPhone(with: lagging) == .continued)
        #expect(lagging.asked.first?.ids == ["1102360418", "1102359994"], "the Mac's next songs")
        #expect(lagging.stationSeeds == ["1102360418"], "then the song's station")
    }
}

/// Continue on Mac through the relay, as the hand-back and Shortcuts do.
@MainActor
@Suite struct ContinueOnMacWithAPlaylistTests {
    private func mac(_ playback: PlaybackMessage) -> SessionState {
        SessionState(sessionID: "s1", mac: PairedMac(id: "a", name: "Studio Mac"), macConnected: true, playback: playback, attributes: nil)
    }

    private func macPlays(_ catalogID: String, title: String = "Song Sixty", at elapsed: TimeInterval = 61.5) -> SessionState {
        var song = TrackMetadata(id: "t9", title: title, artist: "Artist", album: "Album", duration: 279, artworkID: nil)
        song.catalogID = catalogID
        var playback = message(revision: 2, state: .playing, track: song)
        playback.elapsedTime = elapsed
        return mac(playback)
    }

    private func phone(_ catalogID: String, playlist: PlaylistPlace?) -> FakePhoneMusic {
        let phone = FakePhoneMusic()
        phone.current = PhoneNowPlaying(catalogID: catalogID, position: 61, isPlaying: true, title: "Song Sixty")
        phone.playlistHere = playlist
        return phone
    }

    private func handBack(_ relay: FakeRelay, _ phone: FakePhoneMusic, remembering: PlaylistPlace? = nil,
                          rememberingAlbum: AlbumPlace? = nil) async throws -> SendBackOutcome {
        let clock = MutableClock()
        let memory = HandoverMemory(load: { nil }, save: { _ in }, loadPlaylist: { remembering }, savePlaylist: { _ in },
                                    loadAlbum: { rememberingAlbum })
        let remote = MacRemote(client: relay, now: { clock.now }, sleep: { clock.advance($0) }, memory: memory)
        try await remote.read()
        return await remote.handover().sendBackToMac(with: phone)
    }

    @Test func aSongOutsideTheMacsQueueGoesWithThePhonesPlaylist() async throws {
        let relay = FakeRelay(mac(playingFromAA(state: .paused)))
        await relay.setNext(macPlays("270246724"))
        let here = PlaylistPlace(name: "Road Trip", cloudID: "pl.u-Zx9yW8vU7tS6r", count: 123, index: 59)
        let phone = phone("270246724", playlist: here)
        #expect(try await handBack(relay, phone, remembering: aaHere) == .sentBack)
        let sent = await relay.sent.map(\.command)
        #expect(sent.map(\.kind) == [.playStation])
        #expect(sent.first?.playlist == here)
        #expect(sent.first?.catalogID == "270246724" && sent.first?.position == 61 && sent.first?.title == "Song Sixty")
        #expect(phone.remembered == [aaHere], "the playlist Continue on iPhone started is offered too")
        #expect(phone.pauses == 1)
    }

    @Test func farIntoTheMacsQueueThePlaylistBeatsSkipping() async throws {
        let relay = FakeRelay(mac(playingFromAA(state: .paused)))
        await relay.setNext(macPlays("1102359444", title: "Fourth"))
        let phone = phone("1102359444", playlist: PlaylistPlace(name: "Road Trip", count: 123, index: 43))
        phone.current?.title = "Fourth"
        #expect(try await handBack(relay, phone) == .sentBack)
        #expect(await relay.sent.map(\.command.kind) == [.playStation], "one command instead of four skips")
    }

    @Test func aFewSongsOnTheMacSkipsAsBefore() async throws {
        let relay = FakeRelay(mac(playingFromAA(state: .paused)))
        var two = macPlays("1102359746", title: "Sleepers Beat Theme")
        two.playback?.revision = 2
        await relay.setNext(two)
        let phone = phone("1102359746", playlist: aaHere)
        phone.current?.title = "Sleepers Beat Theme"
        #expect(try await handBack(relay, phone) == .sentBack)
        #expect(await relay.sent.map(\.command.kind) == [.next, .next, .seek, .play], "the Mac's queue is the same playlist")
    }

    /// The Mac has the song, but in another queue, as after the song's
    /// station: the phone's playlist goes instead (a six-song playlist, 17 November 2026).
    @Test func theSongInAnotherQueueOnTheMacStillGoesWithThePhonesPlaylist() async throws {
        var stationOnTheMac = playingFromAA(state: .paused)
        stationOnTheMac.playlist = nil
        stationOnTheMac.track?.catalogID = "1510748185"
        let relay = FakeRelay(mac(stationOnTheMac))
        await relay.setNext(macPlays("1510748185", title: "Song Three"))   // where the phone is: no seek from here
        let sunday = PlaylistPlace(name: "Sunday", count: 6, index: 2)
        let phone = phone("1510748185", playlist: sunday)
        phone.current?.title = "Song Three"
        #expect(try await handBack(relay, phone) == .sentBack)
        let sent = await relay.sent.map(\.command)
        #expect(sent.map(\.kind) == [.playStation])
        #expect(sent.first?.playlist == sunday)
    }

    // MARK: Albums (17 November 2026)

    private static let album = AlbumPlace(title: "Album", artist: "Artist", count: 12, index: 5)

    @Test func withoutAPlaylistTheSongGoesWithItsAlbum() async throws {
        let relay = FakeRelay(mac(playingFromAA(state: .paused)))
        await relay.setNext(macPlays("270246724"))
        let phone = phone("270246724", playlist: nil)
        phone.albumHere = Self.album
        #expect(try await handBack(relay, phone) == .sentBack)
        let sent = await relay.sent.map(\.command)
        #expect(sent.map(\.kind) == [.playStation])
        #expect(sent.first?.album == Self.album)
        #expect(sent.first?.playlist == nil)
    }

    @Test func theRememberedAlbumIsOfferedOnTheWayBack() async throws {
        let album = AlbumPlace(title: "Made-Up Album", artist: "Made-Up Band", count: 10, index: 2, shuffled: true)
        let relay = FakeRelay(mac(playingFromAA(state: .paused)))
        await relay.setNext(macPlays("270246724"))
        let back = phone("270246724", playlist: nil)
        back.albumHere = album
        #expect(try await handBack(relay, back, rememberingAlbum: album) == .sentBack)
        #expect(back.rememberedAlbums == [album], "the remembered album is offered")
    }

    @Test func aPausedPhoneSaysItsPositionIsntMovingOn() async throws {
        let relay = FakeRelay(mac(playingFromAA(state: .paused)))
        await relay.setNext(macPlays("270246724"))
        let paused = phone("270246724", playlist: nil)
        paused.current?.isPlaying = false
        #expect(try await handBack(relay, paused) == .sentBack)
        #expect(await relay.sent.map(\.command).first?.positionIsPaused == true)

        let relay2 = FakeRelay(mac(playingFromAA(state: .paused)))
        await relay2.setNext(macPlays("270246724"))
        #expect(try await handBack(relay2, phone("270246724", playlist: nil)) == .sentBack)
        #expect(await relay2.sent.map(\.command).first?.positionIsPaused == nil, "a playing phone leaves it out")
    }

    @Test func aPlaylistMeansTheAlbumIsntLookedUp() async throws {
        let relay = FakeRelay(mac(playingFromAA(state: .paused)))
        await relay.setNext(macPlays("270246724"))
        let phone = phone("270246724", playlist: aaHere)
        phone.albumHere = Self.album
        #expect(try await handBack(relay, phone) == .sentBack)
        let sent = await relay.sent.map(\.command)
        #expect(sent.first?.playlist == aaHere && sent.first?.album == nil)
        #expect(phone.albumAsks == 0)
    }

    /// The Mac played the album, the phone took its next songs: coming back
    /// a song on, the Mac skips ahead in its own queue, which is the album.
    @Test func anAlbumRoundTripSkipsAheadInTheMacsQueue() async throws {
        var albumOnTheMac = playingFromAA(state: .paused)
        albumOnTheMac.playlist = nil
        let relay = FakeRelay(mac(albumOnTheMac))
        var next = macPlays("1102359994", title: "Lady Divine")
        next.playback?.track?.album = "Album"
        await relay.setNext(next)
        let phone = phone("1102359994", playlist: nil)
        phone.current?.title = "Lady Divine"
        phone.albumHere = Self.album
        #expect(try await handBack(relay, phone) == .sentBack)
        #expect(await relay.sent.map(\.command.kind) == [.next, .seek, .play], "the Mac's queue is the album")
    }

    // MARK: Apple Music, stations, the library and repeat (17 November 2026)

    private func handBack(_ relay: FakeRelay, _ phone: FakePhoneMusic, addsToLibrary: Bool) async throws -> SendBackOutcome {
        let clock = MutableClock()
        let memory = HandoverMemory(load: { nil }, save: { _ in }, addsToLibrary: { addsToLibrary })
        let remote = MacRemote(client: relay, now: { clock.now }, sleep: { clock.advance($0) }, memory: memory)
        try await remote.read()
        return await remote.handover().sendBackToMac(with: phone)
    }

    private static let online = PlaylistPlace(name: "Today", cloudID: "pl.f4d106fed2bd", count: 50, index: 5)

    @Test func anAppleMusicPlaylistIsAddedToTheLibraryForTheMac() async throws {
        let relay = FakeRelay(mac(playingFromAA(state: .paused)))
        await relay.setNext(macPlays("270246724"))
        let phone = phone("270246724", playlist: nil)
        phone.appleMusicHere = .playlist(Self.online)
        phone.repeatHere = .one
        #expect(try await handBack(relay, phone, addsToLibrary: true) == .sentBack)
        #expect(phone.added == [.playlist(Self.online)])
        let sent = await relay.sent.map(\.command)
        var expected = Self.online
        expected.addedToLibrary = true
        #expect(sent.first?.playlist == expected)
        #expect(sent.first?.repeatMode == .one)
    }

    @Test func addToLibraryIsOffUntilTurnedOn() {
        let defaults = UserDefaults(suiteName: "addsToLibrary-\(UUID().uuidString)")!
        #expect(HandoverMemory.defaults(defaults).addsToLibrary() == false, "nothing stored: off")
        defaults.set(true, forKey: HandoverMemory.addsToLibraryKey)
        #expect(HandoverMemory.defaults(defaults).addsToLibrary() == true)
        #expect(HandoverMemory.none.addsToLibrary() == false)
    }

    @Test func withTheSettingOffAnAppleMusicPlaylistIsTheSongsStation() async throws {
        let relay = FakeRelay(mac(playingFromAA(state: .paused)))
        await relay.setNext(macPlays("270246724"))
        let phone = phone("270246724", playlist: nil)
        phone.appleMusicHere = .album(AlbumPlace(title: "Made-Up Album", count: 10, index: 2), id: "1440000000")
        #expect(try await handBack(relay, phone, addsToLibrary: false) == .sentBack)
        #expect(phone.added.isEmpty)
        let sent = await relay.sent.map(\.command)
        #expect(sent.first?.playlist == nil && sent.first?.album == nil && sent.first?.station == nil)
    }

    @Test func thePhonesStationGoesToTheMac() async throws {
        let relay = FakeRelay(mac(playingFromAA(state: .paused)))
        await relay.setNext(macPlays("555", title: "Another Song"))   // the station starts on its own song
        let phone = phone("270246724", playlist: nil)
        let radio = StationPlace(id: "ra.985484166", name: "Made-Up Radio")
        phone.appleMusicHere = .station(radio)
        #expect(try await handBack(relay, phone, addsToLibrary: true) == .sentAsStation)
        #expect(await relay.sent.map(\.command).first?.station == radio)
        #expect(phone.added.isEmpty)
        #expect(phone.pauses == 1)
    }

    @Test func aShuffledLibrarySongGoesAsTheLibraryShuffled() async throws {
        let relay = FakeRelay(mac(playingFromAA(state: .paused)))
        await relay.setNext(macPlays("270246724"))
        let phone = phone("270246724", playlist: nil)
        phone.shufflingLibrary = true
        #expect(try await handBack(relay, phone, addsToLibrary: true) == .sentBack)
        let sent = await relay.sent.map(\.command)
        #expect(sent.first?.shuffledLibrary == true)
        #expect(sent.first?.playlist == nil && sent.first?.album == nil)
    }

    /// The Mac played an Apple Music playlist, the phone took it: coming
    /// back a song on, the Mac skips ahead in its own queue; nothing is added.
    @Test func anAppleMusicRoundTripSkipsAheadAndAddsNothing() async throws {
        var onTheMac = playingFromAA(state: .paused)
        onTheMac.playlist = nil
        onTheMac.fromAppleMusic = true
        let relay = FakeRelay(mac(onTheMac))
        await relay.setNext(macPlays("1102359994", title: "Lady Divine"))
        let phone = phone("1102359994", playlist: nil)
        phone.current?.title = "Lady Divine"
        phone.appleMusicHere = .playlist(Self.online)
        #expect(try await handBack(relay, phone, addsToLibrary: true) == .sentBack)
        #expect(await relay.sent.map(\.command.kind) == [.next, .seek, .play])
        #expect(phone.added.isEmpty)
    }

    /// 17 November 2026: Apple Music's recently played is account-wide, and
    /// an old station there looked current for a song Continue on iPhone had
    /// queued from the Mac's Up Next.
    @Test func aSongQueuedFromTheMacsUpNextIsNeverTakenForAnOldStation() async throws {
        let relay = FakeRelay(mac(playingFromAA(state: .paused)))
        await relay.setNext(macPlays("555", title: "Song Five"))
        let phone = phone("555", playlist: aaHere)
        phone.current?.title = "Song Five"
        phone.appleMusicHere = .station(StationPlace(id: "ra.985484166", name: "Made-Up Radio"))
        phone.shufflingLibrary = true
        let clock = MutableClock()
        let memory = HandoverMemory(load: { nil }, save: { _ in }, loadQueued: { ["1102360418", "555"] })
        let remote = MacRemote(client: relay, now: { clock.now }, sleep: { clock.advance($0) }, memory: memory)
        try await remote.read()
        #expect(await remote.handover().sendBackToMac(with: phone) == .sentBack)
        let sent = await relay.sent.map(\.command)
        #expect(sent.map(\.kind) == [.playStation])
        #expect(sent.first?.station == nil && sent.first?.playlist == nil && sent.first?.shuffledLibrary == nil, "the song's station")
        #expect(phone.remembered.isEmpty && phone.albumAsks == 0, "nothing looked up")
    }

    @Test func withoutAPlaylistItsTheStationOrSkipsAsBefore() async throws {
        let outside = FakeRelay(mac(playingFromAA(state: .paused)))
        await outside.setNext(macPlays("270246724"))
        #expect(try await handBack(outside, phone("270246724", playlist: nil)) == .sentBack)
        let sent = await outside.sent.map(\.command)
        #expect(sent.map(\.kind) == [.playStation])
        #expect(sent.first?.playlist == nil)

        let inside = FakeRelay(mac(playingFromAA(state: .paused)))
        await inside.setNext(macPlays("1102359444", title: "Fourth"))
        let far = phone("1102359444", playlist: nil)
        far.current?.title = "Fourth"
        #expect(try await handBack(inside, far) == .sentBack)
        #expect(await inside.sent.map(\.command.kind) == [.next, .next, .next, .next, .seek, .play])
    }
}
