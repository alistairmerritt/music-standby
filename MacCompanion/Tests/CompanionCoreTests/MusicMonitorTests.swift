import Foundation
import Testing
import StandByProtocol
@testable import CompanionCore

/// The quit window: after "Stopped", leave Music alone long enough to exit.
@MainActor
@Suite(.serialized) struct MusicMonitorTests {
    private func monitor(_ music: FakeMusic) -> (MusicMonitor, Box) {
        let monitor = MusicMonitor(controller: MusicController(runner: music, isRunning: music.processCheck), isLaunching: { false })
        monitor.debounce = .milliseconds(20)
        monitor.quitWindow = .milliseconds(300)
        monitor.launchSettle = .milliseconds(100)
        let box = Box()
        monitor.onSnapshot = { snapshot, trigger in box.reads.append((snapshot.state, trigger)) }
        return (monitor, box)
    }

    final class Box { var reads: [(PlaybackState, MusicMonitor.Trigger)] = [] }

    @Test func stoppedHoldsEveryReadUntilTheWindowEnds() async throws {
        let music = FakeMusic(state: "playing")
        let (monitor, box) = monitor(music)
        monitor.playerInfoArrived(playerState: "Stopped")
        monitor.requestRead(.poll)
        #expect(monitor.isHolding)
        try await Task.sleep(for: .milliseconds(150))
        #expect(music.scripts.isEmpty)
        #expect(box.reads.isEmpty)
        // Music exits inside the window: the held read must not send it anything.
        music.running = false
        try await Task.sleep(for: .milliseconds(300))
        #expect(music.scripts.isEmpty)
        #expect(box.reads.map(\.0) == [.notRunning])
        #expect(!monitor.isHolding)
    }

    @Test func stoppedWithoutQuittingIsReadAfterTheWindow() async throws {
        let music = FakeMusic(state: "stopped")
        let (monitor, box) = monitor(music)
        monitor.playerInfoArrived(playerState: "Stopped")
        try await Task.sleep(for: .milliseconds(450))
        #expect(box.reads.map(\.0) == [.stopped])
        #expect(music.scripts == [.snapshot])
    }

    @Test func otherNotificationsAreReadPromptly() async throws {
        let music = FakeMusic(state: "playing")
        let (monitor, box) = monitor(music)
        monitor.playerInfoArrived(playerState: "Playing")
        monitor.playerInfoArrived(playerState: "Playing")   // the usual duplicate
        try await Task.sleep(for: .milliseconds(120))
        #expect(box.reads.map(\.0) == [.playing])
    }

    @Test func aRelaunchIsReadOnceMusicHasSettled() async throws {
        let music = FakeMusic(state: "stopped")
        let (monitor, box) = monitor(music)
        monitor.playerInfoArrived(playerState: "Stopped")
        monitor.requestRead(.launch)
        monitor.requestRead(.poll)
        try await Task.sleep(for: .milliseconds(50))
        #expect(music.scripts.isEmpty)
        try await Task.sleep(for: .milliseconds(150))
        #expect(box.reads.map(\.1) == [.launch])
        #expect(!monitor.isHolding)
    }

    @Test func commandsWaitOutTheWindow() async throws {
        let music = FakeMusic(state: "playing")
        let (monitor, _) = monitor(music)
        monitor.playerInfoArrived(playerState: "Stopped")
        let started = ContinuousClock.now
        await monitor.waitOutQuitWindow()
        #expect(ContinuousClock.now - started >= .milliseconds(250))
    }

    @Test func noAppleEventsUntilMusicHasFinishedLaunching() async throws {
        let music = FakeMusic(state: "stopped")
        var launching = true
        let monitor = MusicMonitor(controller: MusicController(runner: music, isRunning: music.processCheck), isLaunching: { launching })
        let box = Box()
        monitor.onSnapshot = { snapshot, trigger in box.reads.append((snapshot.state, trigger)) }
        monitor.launchSettle = .milliseconds(50)
        monitor.requestRead(.launch)
        try await Task.sleep(for: .milliseconds(200))
        #expect(music.scripts.isEmpty)
        launching = false
        try await Task.sleep(for: .milliseconds(450))
        #expect(box.reads.map(\.1) == [.launch])
        #expect(music.scripts == [.snapshot])
    }
}
