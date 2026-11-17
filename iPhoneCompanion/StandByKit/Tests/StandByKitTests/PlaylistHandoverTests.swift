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

    @Test func theMacsNextSongsWhenThePlaylistIsntHere() async {
        let (h, task) = await ready(playingFromAA())
        defer { task.cancel() }
        HandoverMemory.defaults(h.defaults).savePlaylist(aaHere)
        let phone = FakePhoneMusic()
        #expect(await h.model.continueOnPhone(with: phone) == .continued)
        #expect(phone.playlistAsked.count == 1)
        #expect(phone.asked.first?.ids == ["1102360418", "1102359994", "1102359746", "1102359555", "1102359444"])
        #expect(HandoverMemory.defaults(h.defaults).loadPlaylist() == nil, "an old playlist isn't kept")
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

    @Test func aShuffledOrUnusablePlaceIsIgnored() async {
        for place in [PlaylistPlace(name: "Road Trip", count: 123, index: 39, shuffled: true), PlaylistPlace(name: "Road Trip", count: 3, index: 9)] {
            let (h, task) = await ready(playingFromAA(at: place))
            let phone = FakePhoneMusic()
            phone.playsPlaylist = aaHere
            #expect(await h.model.continueOnPhone(with: phone) == .continued)
            #expect(phone.playlistAsked.isEmpty)
            #expect(phone.asked.count == 1)
            task.cancel()
        }
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

    private func handBack(_ relay: FakeRelay, _ phone: FakePhoneMusic, remembering: PlaylistPlace? = nil) async throws -> SendBackOutcome {
        let clock = MutableClock()
        let memory = HandoverMemory(load: { nil }, save: { _ in }, loadPlaylist: { remembering }, savePlaylist: { _ in })
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
