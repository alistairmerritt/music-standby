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
        await eventually("catalogue ID seen") { h.model.canContinueOnPhone == (m.track?.catalogID != nil) && h.controller.isActive }
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

        let (plain, plainTask) = await ready(message())
        defer { plainTask.cancel() }
        #expect(!plain.model.canContinueOnPhone)
        let phone = FakePhoneMusic()
        #expect(await plain.model.continueOnPhone(with: phone) == .unavailable)
        #expect(phone.asked.isEmpty)
        #expect(await plain.transport.sent.isEmpty)
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

    @Test func sendsNothingForASongTheMacDoesntHave() async {
        let (h, task) = await handedOver()
        defer { task.cancel() }
        let phone = FakePhoneMusic()
        phone.current = PhoneNowPlaying(catalogID: "999", position: 10, isPlaying: true)
        #expect(await h.model.sendBackToMac(with: phone) == .notInMacQueue)
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
