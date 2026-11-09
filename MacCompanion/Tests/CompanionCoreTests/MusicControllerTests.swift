import Foundation
import Testing
import StandByProtocol
@testable import CompanionCore

@MainActor
@Suite struct MusicControllerTests {
    @Test func closedMusicGetsNoAppleEvents() async {
        let music = FakeMusic()
        music.running = false
        let controller = MusicController(runner: music, isRunning: music.processCheck)
        #expect(controller.snapshot().state == .notRunning)
        #expect(controller.artwork() == .notRunning)
        #expect(controller.perform(.play) == .notRunning)
        #expect(music.scripts.isEmpty)
        #expect(controller.scriptsRun == 0)
        #expect(controller.skippedWhileClosed == 3)
    }

    @Test func inScriptGuardCatchesAQuitAfterTheProcessCheck() async {
        let music = FakeMusic()
        music.running = false
        // The process check still says running; the script's own guard says not.
        let controller = MusicController(runner: music, isRunning: { true })
        #expect(controller.snapshot().state == .notRunning)
        #expect(controller.perform(.next) == .notRunning)
    }

    @Test func refusedPermissionIsNeverReportedAsClosed() async {
        let music = FakeMusic()
        music.denied = true
        let controller = MusicController(runner: music, isRunning: music.processCheck)
        let snapshot = controller.snapshot()
        #expect(snapshot.state == .automationDenied)
        #expect(snapshot.detail?.contains("-1743") == true)
        guard case .automationDenied = controller.perform(.play) else { Issue.record("expected automationDenied"); return }
        guard case .failed(.automationDenied, _) = controller.artwork() else { Issue.record("expected failed(.automationDenied)"); return }
    }

    @Test func procNotFoundCountsAsClosedOnlyIfTheProcessIsGone() async {
        let music = FakeMusic()
        let controller = MusicController(runner: music, isRunning: music.processCheck)
        music.failNext(code: -600, message: "Application isn’t running.")
        #expect(controller.snapshot().state == .error)
        music.quitDuringNextScript()
        #expect(controller.snapshot().state == .notRunning)
    }

    @Test func timeoutIsAnError() async {
        let music = FakeMusic()
        let controller = MusicController(runner: music, isRunning: music.processCheck)
        music.failNext(code: -1712, message: "AppleEvent timed out.")
        let snapshot = controller.snapshot()
        #expect(snapshot.state == .error)
        #expect(snapshot.detail?.contains("-1712") == true)
    }

    @Test func readsTheCurrentTrack() async throws {
        let music = FakeMusic(state: "playing")
        let controller = MusicController(runner: music, isRunning: music.processCheck)
        let snapshot = controller.snapshot()
        #expect(snapshot.state == .playing)
        #expect(snapshot.position == 10)
        let track = try #require(snapshot.track)
        #expect(track.title == "Losing My Edge")
        #expect(track.duration == 473.114)
        #expect(track.trackID == "pid:542CEB17C137B39E")
        #expect(track.trackClass == "URL track")
        #expect(track.artworkCount == 1)
    }

    @Test func artworkComesBackWithItsTrack() async {
        let music = FakeMusic()
        let controller = MusicController(runner: music, isRunning: music.processCheck)
        #expect(controller.artwork() == .image(music.current.artwork!, persistentID: "542CEB17C137B39E", descriptorType: "PNGf"))
        _ = controller.perform(.next)
        #expect(controller.artwork() == .noArtwork(persistentID: "542CEB17C137B3A5"))
        music.state = "stopped"
        #expect(controller.artwork() == .noTrack)
    }
}

@Suite struct SnapshotParserTests {
    private let sep = SnapshotParser.separator
    private let date = Date(timeIntervalSince1970: 1000)

    @Test func parsesAFullRecord() {
        let raw = ["playing", "251.04", "Losing My Edge", "LCD Soundsystem", "LCD Soundsystem", "", "473.114", "542CEB17C137B39E", "86657", "URL track", "1"].joined(separator: sep)
        let s = SnapshotParser.parse(raw, capturedAt: date)
        #expect(s.state == .playing)
        #expect(s.position == 251.04)
        #expect(s.track?.albumArtist == nil)
        #expect(s.track?.databaseID == 86657)
        #expect(s.capturedAt == date)
    }

    @Test func stoppedHasNoTrack() {
        let s = SnapshotParser.parse(["stopped", "0", "", "", "", "", "0", "", "0", "", "0"].joined(separator: sep), capturedAt: date)
        #expect(s.state == .stopped)
        #expect(s.track == nil)
    }

    @Test func acceptsCommaDecimals() {
        let s = SnapshotParser.parse(["paused", "12,5", "T", "A", "B", "", "205,307", "X", "1", "file track", "0"].joined(separator: sep), capturedAt: date)
        #expect(s.position == 12.5)
        #expect(s.track?.duration == 205.307)
    }

    @Test func fastForwardingIsPlaying() {
        #expect(SnapshotParser.state("fast forwarding") == .playing)
        #expect(SnapshotParser.state("rewinding") == .playing)
        #expect(SnapshotParser.state("something new") == .stopped)
    }

    @Test func toleratesShortRecords() {
        let s = SnapshotParser.parse(["paused", "3", "Only a title"].joined(separator: sep), capturedAt: date)
        #expect(s.track?.title == "Only a title")
        #expect(s.track?.duration == 0)
        #expect(s.track?.trackID.hasPrefix("key:") == true)
    }
}

@Suite struct ArtworkProcessorTests {
    @Test func idIsTheHashOfTheSourceAndTheServedCopyIsSmaller() throws {
        let source = FakeMusic.png(side: 800)
        let processed = try #require(ArtworkProcessor.process(source))
        #expect(processed.artworkID == ArtworkID.make(sourceBytes: source))
        #expect(processed.sourceFormat == "png")
        #expect(processed.descriptor.contentType == "image/jpeg")
        #expect(processed.descriptor.width == 600)
        #expect(processed.descriptor.height == 600)
        #expect(processed.descriptor.byteCount == processed.image.count)
        #expect(ArtworkProcessor.format(of: processed.image) == "jpeg")
    }

    @Test func smallArtworkIsNotUpscaled() throws {
        let processed = try #require(ArtworkProcessor.process(FakeMusic.png(side: 300)))
        #expect(processed.descriptor.width == 300)
    }

    @Test func undecodableBytesGiveNil() {
        #expect(ArtworkProcessor.process(Data("not an image".utf8)) == nil)
    }
}

@Suite struct SnapshotNumberTests {
    @Test func roundsToMilliseconds() {
        #expect(SnapshotParser.number("205.307006835938") == 205.307)
        #expect(SnapshotParser.number("nan") == nil)
    }
}
