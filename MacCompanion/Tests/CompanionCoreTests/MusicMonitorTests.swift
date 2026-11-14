import Foundation
import Testing
import StandByProtocol
@testable import CompanionCore

/// No quit window since events go by PID; a launch still settles first.
@MainActor
@Suite(.serialized) struct MusicMonitorTests {
    private func monitor(_ music: FakeMusic) -> (MusicMonitor, Box) {
        let monitor = MusicMonitor(controller: MusicController(runner: music, isRunning: music.processCheck), isLaunching: { false })
        monitor.debounce = .milliseconds(20)
        monitor.launchSettle = .milliseconds(100)
        let box = Box()
        monitor.onSnapshot = { snapshot, trigger in box.reads.append((snapshot.state, trigger)) }
        return (monitor, box)
    }

    final class Box { var reads: [(PlaybackState, MusicMonitor.Trigger)] = [] }

    /// The AppleScript version held every read for 2 s after "Stopped".
    @Test func stoppedIsReadPromptly() async throws {
        let music = FakeMusic(state: "stopped")
        let (monitor, box) = monitor(music)
        monitor.playerInfoArrived(playerState: "Stopped")
        #expect(!monitor.isHolding)
        try await Task.sleep(for: .milliseconds(120))
        #expect(box.reads.map(\.0) == [.stopped])
        #expect(music.scripts == [.snapshot])
    }

    /// Music quitting between the notification and the read: the process
    /// check answers, with no Apple Event.
    @Test func aQuitAfterTheNotificationIsNotRunning() async throws {
        let music = FakeMusic(state: "playing")
        let (monitor, box) = monitor(music)
        monitor.playerInfoArrived(playerState: "Paused")
        music.running = false
        try await Task.sleep(for: .milliseconds(120))
        #expect(box.reads.map(\.0) == [.notRunning])
        #expect(music.scripts.isEmpty)
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
        monitor.requestRead(.launch)
        #expect(monitor.isHolding)
        monitor.requestRead(.poll)
        try await Task.sleep(for: .milliseconds(50))
        #expect(music.scripts.isEmpty)
        try await Task.sleep(for: .milliseconds(150))
        #expect(box.reads.map(\.1) == [.launch])
        #expect(!monitor.isHolding)
    }

    @Test func commandsWaitOutALaunch() async throws {
        let music = FakeMusic(state: "stopped")
        let (monitor, _) = monitor(music)
        monitor.requestRead(.launch)
        let started = ContinuousClock.now
        await monitor.waitOutLaunch()
        #expect(ContinuousClock.now - started >= .milliseconds(80))
        #expect(!monitor.isHolding)
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
