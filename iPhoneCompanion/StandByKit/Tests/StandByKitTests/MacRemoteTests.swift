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

    @Test func sendsNothingWithoutAConnectedMacOrASession() async throws {
        let offline = FakeRelay(state(connected: false))
        await #expect(throws: TransportError.notConnected) { try await MacRemote(client: offline).run(.play) }
        let noSession = FakeRelay(state(session: nil))
        await #expect(throws: TransportError.commandRejected(.noSession)) { try await MacRemote(client: noSession).run(.play) }
        let offlineSent = await offline.sent, noSessionSent = await noSession.sent
        #expect(offlineSent.isEmpty && noSessionSent.isEmpty)
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
    private(set) var sent: [(command: RemoteCommand, sessionID: String)] = []
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

    func send(_ command: RemoteCommand, sessionID: String) async throws -> CommandAck {
        sent.append((command, sessionID))
        guard sessionID == currentSession else { throw TransportError.commandRejected(.sessionMismatch) }
        if let refusal { return .rejected(command.id, revision: 1, ProtocolError(refusal)) }
        return .accepted(command.id, revision: 1)
    }
}
