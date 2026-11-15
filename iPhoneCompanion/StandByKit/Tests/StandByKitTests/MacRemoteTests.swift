import Foundation
import Testing
@testable import StandByKit

/// The relay as a Shortcuts action sees it: what each sends, under which
/// session, and what stops it before it sends. Added 12 November 2026.
@MainActor
@Suite struct MacRemoteTests {
    private func state(session: String? = "s1", connected: Bool = true, playback: PlaybackMessage? = message()) -> SessionState {
        SessionState(sessionID: session, mac: PairedMac(id: "a", name: "Studio Mac"), macConnected: connected, playback: playback, attributes: nil)
    }

    @Test func sendsUnderTheSessionItReadOnce() async throws {
        let relay = FakeRelay(state(session: "s1"))
        let remote = MacRemote(client: relay)
        try await remote.run(.next)
        try await remote.seek(to: 120)
        try await remote.setVolume(0.3)
        let sent = await relay.sent
        #expect(sent.map(\.command.kind) == [.next, .seek, .setVolume])
        #expect(sent.allSatisfy { $0.sessionID == "s1" })
        #expect(sent[1].command.position == 120)
        #expect(sent[2].command.level == 0.3)
        #expect(await relay.reads == 1)
    }

    @Test func aSessionThatChangedGetsOneFreshReadAndOneMoreTry() async throws {
        let relay = FakeRelay(state(session: "old"))
        await relay.setCurrentSession("new")
        let remote = MacRemote(client: relay)
        try await remote.run(.pause)
        #expect(await relay.sent.map(\.sessionID) == ["old", "new"])
        #expect(await relay.reads == 2)
    }

    @Test func sendsNothingWithoutAConnectedMac() async throws {
        let offline = FakeRelay(state(connected: false))
        await #expect(throws: TransportError.notConnected) { try await MacRemote(client: offline).run(.play) }
        #expect(await offline.sent.isEmpty)
    }

    /// The session had ended overnight while the phone had the music, so
    /// Continue from iPhone failed in half a second (16 November 2026).
    @Test func withoutASessionItSendsNamingNone() async throws {
        let noSession = FakeRelay(state(session: nil))
        try await MacRemote(client: noSession).run(.play)
        let sent = await noSession.sent
        #expect(sent.map(\.command.kind) == [.play])
        #expect(sent.first?.sessionID == nil)
    }

    @Test func aRefusalFromTheMacIsAnError() async throws {
        let relay = FakeRelay(state())
        await relay.refuse(with: .commandFailed)
        await #expect(throws: TransportError.commandRejected(.commandFailed)) { try await MacRemote(client: relay).run(.next) }
    }

    @Test func playOrPauseFollowsTheMac() async throws {
        let playing = FakeRelay(state(playback: message(state: .playing)))
        #expect(try await MacRemote(client: playing).playOrPause() == .pause)
        let paused = FakeRelay(state(playback: message(state: .paused)))
        #expect(try await MacRemote(client: paused).playOrPause() == .play)
        let stopped = FakeRelay(state(playback: nil))
        #expect(try await MacRemote(client: stopped).playOrPause() == .play)
    }

    @Test func valuesAreKeptInRange() async throws {
        let relay = FakeRelay(state())
        let remote = MacRemote(client: relay)
        try await remote.setVolume(1.4)
        try await remote.setVolume(-1)
        try await remote.seek(to: -5)
        let values = await relay.sent.map { $0.command.level ?? $0.command.position }
        #expect(values == [1, 0, 0])
    }

    @Test func aJumpPastTheEndOfTheSongIsRefused() async throws {
        let relay = FakeRelay(state(playback: message()))   // a 200 s song
        let remote = MacRemote(client: relay)
        await #expect(throws: MacRemoteError.pastTheEnd(200)) { try await remote.seek(to: 1800) }
        await #expect(throws: MacRemoteError.pastTheEnd(200)) { try await remote.seek(to: 200) }
        try await remote.seek(to: 199)
        #expect(await relay.sent.map(\.command.position) == [199])
        #expect(MacRemoteError.pastTheEnd(200.7).errorDescription == "The song on your Mac is only 3:20.")
    }

    @Test func continuesOnThePhoneFromTheRelaysStateAndPausesTheMac() async throws {
        var song = track()
        song.catalogID = "1102360418"
        var playing = message(state: .playing, track: song)
        playing.elapsedTime = 30
        playing.upNext = [QueuedTrack(catalogID: "1102359994", title: "Lady Divine", artist: "Alela Diane", duration: 312)]
        let relay = FakeRelay(state(playback: playing))
        let twelveSecondsLater = playing.capturedAt.addingTimeInterval(12)
        let remote = MacRemote(client: relay, now: { twelveSecondsLater })
        try await remote.read()
        let phone = FakePhoneMusic()
        #expect(await remote.handover().continueOnPhone(with: phone) == .continued)
        #expect(phone.asked.first?.ids == ["1102360418", "1102359994"])
        #expect(phone.asked.first?.position == 42, "the Mac's position, run on to now")
        #expect(await relay.sent.map(\.command.kind) == [.pause])
        #expect(await relay.sent.first?.sessionID == "s1")
        #expect(await relay.sent.first?.command.reason == .continueOnPhone, "so the Mac offers Continue from iPhone")
    }

    @Test func continuesOnTheMacOnceTheRelaySaysItPlays() async throws {
        var song = track()
        song.catalogID = "1102359994"
        let relay = FakeRelay(state(playback: message(state: .paused, track: song)))
        let remote = MacRemote(client: relay, sleep: { _ in })
        try await remote.read()
        let phone = FakePhoneMusic()
        phone.current = PhoneNowPlaying(catalogID: "1102359994", position: 61, isPlaying: true)
        // The relay's next read shows the Mac playing it.
        await relay.setNext(state(playback: message(revision: 2, state: .playing, track: song)))
        #expect(await remote.handover().sendBackToMac(with: phone) == .sentBack)
        #expect(await relay.sent.map(\.command.kind) == [.seek, .play])
        #expect(phone.pauses == 1)
    }
}

@MainActor
@Suite struct StopShowingFromAShortcutTests {
    @Test func endsASessionLeftFromAnEarlierRunOfTheApp() async {
        // A fresh launch: nothing held yet, showing still on.
        let h = Harness()
        h.controller.leftoverSessionID = "earlier"
        await h.model.stopNowPlaying()
        #expect(h.controller.deactivations == 1)
        #expect(!h.model.isNowPlayingEnabled)
    }

    @Test func withNothingLeftThereIsNothingToEnd() async {
        let h = Harness()
        await h.model.stopNowPlaying()
        #expect(h.controller.deactivations == 0)
        #expect(!h.model.isNowPlayingEnabled)
    }
}

/// The relay for one pairing: a state to read and commands that come back
/// accepted, unless told otherwise.
actor FakeRelay: MacRemote.Client {
    private var state: SessionState
    private var next: SessionState?
    private var currentSession: String?
    private var refusal: ErrorCode?
    private(set) var sent: [(command: RemoteCommand, sessionID: String?)] = []
    private(set) var reads = 0

    init(_ state: SessionState) {
        self.state = state
        currentSession = state.sessionID
    }

    /// The relay has moved on to another session since the first read.
    func setCurrentSession(_ id: String) {
        currentSession = id
        var moved = state
        moved.sessionID = id
        next = moved
    }

    /// What every read after the first returns.
    func setNext(_ state: SessionState) { next = state }

    func refuse(with code: ErrorCode) { refusal = code }

    func fetchSession(timeout: TimeInterval) async throws -> SessionState {
        reads += 1
        if reads > 1, let next { return next }
        return state
    }

    func send(_ command: RemoteCommand, sessionID: String?) async throws -> CommandAck {
        sent.append((command, sessionID))
        // As the relay since 16 November 2026: a command naming a session must
        // name the current one; one naming none goes through.
        if let sessionID {
            guard currentSession != nil else { throw TransportError.commandRejected(.noSession) }
            guard sessionID == currentSession else { throw TransportError.commandRejected(.sessionMismatch) }
        }
        if let refusal { return .rejected(command.id, revision: 1, ProtocolError(refusal)) }
        return .accepted(command.id, revision: 1)
    }
}

private let handoverStart = Date(timeIntervalSince1970: 1_000_000)

/// Continue on iPhone run a second time, as a CarPlay automation does on the
/// next drive: the Mac is still paused where it stopped for the phone, and
/// the phone has played on since. Added 15 November 2026.
@MainActor
@Suite struct ContinueOnPhoneAgainTests {
    let memory = HandoverMemory.defaults(UserDefaults(suiteName: "handover-\(UUID().uuidString)")!)

    private func mac(_ state: PlaybackState, at elapsed: TimeInterval, song catalogID: String = "1102360418", revision: UInt64 = 1) -> SessionState {
        var song = track()
        song.catalogID = catalogID
        var playback = message(revision: revision, state: state, track: song)
        playback.elapsedTime = elapsed
        return SessionState(sessionID: "s1", mac: PairedMac(id: "a", name: "Studio Mac"), macConnected: true, playback: playback, attributes: nil)
    }

    private func remote(_ relay: FakeRelay, after seconds: TimeInterval) async throws -> MacRemote {
        let remote = MacRemote(client: relay, now: { handoverStart.addingTimeInterval(seconds) }, sleep: { _ in }, memory: memory)
        try await remote.read()
        return remote
    }

    /// The first drive: the Mac plays from 30 s and stops at 42 s for the phone.
    private func continueOnce(_ phone: FakePhoneMusic) async throws {
        let first = try await remote(FakeRelay(mac(.playing, at: 30)), after: 12)
        #expect(await first.handover().continueOnPhone(with: phone) == .continued)
        #expect(memory.load()?.position == 42)
    }

    @Test func theNextTimeThePhoneCarriesOnInsteadOfStartingTheMacsSongAgain() async throws {
        let phone = FakePhoneMusic()
        try await continueOnce(phone)
        // The phone played on into the queue and paused when the car stopped.
        phone.current = PhoneNowPlaying(catalogID: "1102359994", position: 95, isPlaying: false)
        let relay = FakeRelay(mac(.paused, at: 42.4, revision: 2))
        let nextDay = try await remote(relay, after: 86_400)
        #expect(await nextDay.handover().continueOnPhone(with: phone) == .resumedHere)
        #expect(phone.resumes == 1)
        #expect(phone.asked.count == 1, "the Mac's song isn't started again")
        #expect(await relay.sent.isEmpty, "nothing goes to the Mac")
    }

    @Test func aPhoneAlreadyPlayingIsLeftAlone() async throws {
        let phone = FakePhoneMusic()
        try await continueOnce(phone)
        phone.current = PhoneNowPlaying(catalogID: "1102359994", position: 95, isPlaying: true)
        let relay = FakeRelay(mac(.paused, at: 42, revision: 2))
        #expect(try await remote(relay, after: 600).handover().continueOnPhone(with: phone) == .alreadyPlayingHere)
        #expect(phone.resumes == 0 && phone.asked.count == 1)
        #expect(await relay.sent.isEmpty)
    }

    @Test func aMacThatHasMovedOnIsContinuedAgain() async throws {
        let movedOn = [
            mac(.playing, at: 60, revision: 2),                       // playing again
            mac(.paused, at: 150, revision: 2),                       // played on, then paused
            mac(.paused, at: 42, song: "1102359746", revision: 2),    // another song
        ]
        for state in movedOn {
            let phone = FakePhoneMusic()
            try await continueOnce(phone)
            phone.current = PhoneNowPlaying(catalogID: "1102359994", position: 95, isPlaying: false)
            let later = try await remote(FakeRelay(state), after: 600)
            #expect(await later.handover().continueOnPhone(with: phone) == .continued)
            #expect(phone.asked.count == 2 && phone.resumes == 0)
        }
    }

    @Test func aPhoneWithNothingToResumeTakesTheMacsSong() async throws {
        let phone = FakePhoneMusic()
        try await continueOnce(phone)
        phone.current = nil
        let later = try await remote(FakeRelay(mac(.paused, at: 42, revision: 2)), after: 600)
        #expect(await later.handover().continueOnPhone(with: phone) == .continued)
        #expect(phone.asked.count == 2)
    }

    @Test func continuingOnTheMacForgetsIt() async throws {
        let phone = FakePhoneMusic()
        try await continueOnce(phone)
        phone.current = PhoneNowPlaying(catalogID: "1102360418", position: 61, isPlaying: true)
        let relay = FakeRelay(mac(.paused, at: 42, revision: 2))
        await relay.setNext(mac(.playing, at: 61, revision: 3))
        #expect(try await remote(relay, after: 60).handover().sendBackToMac(with: phone) == .sentBack)
        #expect(memory.load() == nil, "the Mac has the music again, so the next Continue on iPhone takes it")
    }
}

/// Continue on iPhone from a Mac with little to come, as on a station, which
/// lists only its next song: a station made from the song follows here.
/// Added 15 November 2026.
@MainActor
@Suite struct ContinueWithAStationTests {
    private func mac(upNext ids: [String?]) -> FakeRelay {
        var song = track()
        song.catalogID = "1102360418"
        var playback = message(state: .playing, track: song)
        playback.upNext = ids.enumerated().map { QueuedTrack(catalogID: $1, title: "Next \($0)", artist: "Artist", duration: 200) }
        return FakeRelay(SessionState(sessionID: "s1", mac: PairedMac(id: "a", name: "Studio Mac"), macConnected: true, playback: playback, attributes: nil))
    }

    private func continueHere(_ relay: FakeRelay, _ phone: FakePhoneMusic) async throws -> ContinueOutcome {
        let remote = MacRemote(client: relay, sleep: { _ in })
        try await remote.read()
        return await remote.handover().continueOnPhone(with: phone)
    }

    @Test func aMacOnAStationIsFollowedByAStationFromTheSong() async throws {
        let relay = mac(upNext: ["1102359994"])   // what a station lists
        let phone = FakePhoneMusic()
        #expect(try await continueHere(relay, phone) == .continued)
        #expect(phone.asked.first?.ids == ["1102360418", "1102359994"])
        #expect(phone.stationSeeds == ["1102360418"], "the station is made from the song that was playing")
        #expect(await relay.sent.map(\.command.kind) == [.pause], "the Mac pauses as before")
    }

    @Test func songsWithoutACatalogueIDDontCountAsToCome() async throws {
        let phone = FakePhoneMusic()
        _ = try await continueHere(mac(upNext: ["1102359994", nil, nil, nil]), phone)
        #expect(phone.stationSeeds == ["1102360418"])
    }

    @Test func aFullUpNextNeedsNoStation() async throws {
        let phone = FakePhoneMusic()
        #expect(try await continueHere(mac(upNext: ["1", "2", "3"]), phone) == .continued)
        #expect(phone.stationSeeds.isEmpty)
    }

    @Test func aStationThatCantBeAddedChangesNothingElse() async throws {
        for result in [StationAppend.failed("catalogue: no developer token"), .noStation] {
            let relay = mac(upNext: [])
            let phone = FakePhoneMusic()
            phone.station = result
            #expect(try await continueHere(relay, phone) == .continued)
            #expect(await relay.sent.map(\.command.kind) == [.pause])
        }
    }

    @Test func noStationWhenTheSongDidntStartHere() async throws {
        let phone = FakePhoneMusic()
        phone.starts = false
        #expect(try await continueHere(mac(upNext: []), phone) == .didNotStart)
        #expect(phone.stationSeeds.isEmpty)
    }
}

/// Continue on Mac for a song the Mac's queue doesn't have, as after the
/// phone has played into a station: the Mac plays the song's station.
/// Added 15 November 2026.
@MainActor
@Suite struct ContinueOnMacWithAStationTests {
    private func mac(_ playback: PlaybackMessage) -> SessionState {
        SessionState(sessionID: "s1", mac: PairedMac(id: "a", name: "Studio Mac"), macConnected: true, playback: playback, attributes: nil)
    }

    /// The Mac paused on the song it handed over, revision 1.
    private func pausedMac() -> FakeRelay {
        var song = track("t1")
        song.catalogID = "1102360418"
        return FakeRelay(mac(message(revision: 1, state: .paused, track: song)))
    }

    private func macPlays(_ catalogID: String?, id: String = "t2", title: String = "Song", at elapsed: TimeInterval = 0) -> SessionState {
        var song = TrackMetadata(id: id, title: title, artist: "Artist", album: "Album", duration: 200, artworkID: nil)
        song.catalogID = catalogID
        var playback = message(revision: 2, state: .playing, track: song)
        playback.elapsedTime = elapsed
        return mac(playback)
    }

    private func phone(_ catalogID: String = "999", title: String? = "Song") -> FakePhoneMusic {
        let phone = FakePhoneMusic()
        phone.current = PhoneNowPlaying(catalogID: catalogID, position: 61, isPlaying: true, title: title)
        return phone
    }

    private func handBack(_ relay: FakeRelay, _ phone: FakePhoneMusic) async throws -> SendBackOutcome {
        let clock = MutableClock()
        let remote = MacRemote(client: relay, now: { clock.now }, sleep: { clock.advance($0) })
        try await remote.read()
        return await remote.handover().sendBackToMac(with: phone)
    }

    @Test func theMacIsToldWhereThePhoneIsAndSeeksItself() async throws {
        let relay = pausedMac()
        await relay.setNext(macPlays("999", at: 61.5))   // the Mac's own seek has landed
        let phone = phone()
        #expect(try await handBack(relay, phone) == .sentBack)
        let sent = await relay.sent.map(\.command)
        #expect(sent.map(\.kind) == [.playStation], "no seek from the phone")
        #expect(sent.first?.catalogID == "999")
        #expect(sent.first?.position == 61 && sent.first?.title == "Song")
        #expect(phone.pauses == 1)
    }

    @Test func aMacThatDoesntSeekIsSeekedFromThePhone() async throws {
        let relay = pausedMac()
        await relay.setNext(macPlays("999"))   // an older Mac: still at the start of the song
        let phone = phone()
        #expect(try await handBack(relay, phone) == .sentBack)
        let sent = await relay.sent.map(\.command)
        #expect(sent.map(\.kind) == [.playStation, .seek])
        #expect(abs((sent.last?.position ?? 0) - 61.3) < 0.01)
        #expect(phone.pauses == 1)
    }

    @Test func beforeItsCatalogueIDIsInTheSongIsKnownByTitle() async throws {
        let relay = pausedMac()
        await relay.setNext(macPlays(nil, title: "SONG"))
        #expect(try await handBack(relay, phone(title: "song")) == .sentBack)
        #expect(await relay.sent.map(\.command.kind) == [.playStation, .seek])
    }

    @Test func aStationStartingWithAnotherSongStillTakesOverWithoutASeek() async throws {
        let relay = pausedMac()
        await relay.setNext(macPlays("777", title: "Another Song"))
        let phone = phone()
        #expect(try await handBack(relay, phone) == .sentAsStation)
        #expect(await relay.sent.map(\.command.kind) == [.playStation])
        #expect(phone.pauses == 1)
    }

    @Test func anOlderMacSaysNoAndThePhoneCarriesOn() async throws {
        let relay = pausedMac()
        await relay.refuse(with: .unsupportedCommand)
        let phone = phone()
        #expect(try await handBack(relay, phone) == .macRefused)
        #expect(phone.pauses == 0)
    }

    @Test func aMacThatNeverStartsGivesUpAndThePhoneCarriesOn() async throws {
        let relay = pausedMac()   // every read shows the Mac still paused
        let phone = phone()
        #expect(try await handBack(relay, phone) == .macDidNotStart)
        #expect(phone.pauses == 0)
    }
}
