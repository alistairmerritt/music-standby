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

    @Test func doesntPauseAMacThatIsAlreadyPaused() async {
        let (h, task) = await ready(continuable(state: .paused))
        defer { task.cancel() }
        h.clock.advance(42)
        let phone = FakePhoneMusic()
        #expect(await h.model.continueOnPhone(with: phone) == .continued)
        #expect(phone.asked.first?.position == 0, "a paused Mac's position doesn't run on")
        #expect(await h.transport.sent.isEmpty)
    }
}
