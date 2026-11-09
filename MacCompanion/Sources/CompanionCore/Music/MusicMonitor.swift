import AppKit
import Foundation
import StandByProtocol

/// Decides when to read Music.app, and hands every read to `onSnapshot`.
///
/// Three signals, because each misses something (spike FINDINGS.md):
/// - `com.apple.Music.playerInfo`: play, pause, track change. Often arrives
///   twice, carries no persistent ID or position, and fires with only
///   "Stopped" on quit. Used as a trigger, debounced, then Music is re-read.
/// - NSWorkspace launch and terminate, filtered to Music: the only reliable
///   app-lifecycle signal. `playerInfo` says nothing at all on launch.
/// - A slow poll, to keep position honest and catch anything missed. While
///   Music is closed the poll is a process check only, with no Apple Events.
///
/// Reads never overlap. A trigger that arrives mid-read causes one more read.
///
/// **Quit window.** Quitting Music sends `playerInfo` "Stopped", then Music
/// takes about a second to exit, and both launch guards still say "running"
/// throughout. An Apple Event sent then makes macOS relaunch Music: measured
/// on macOS 27.0.1, the companion's own debounced read did exactly that
/// (LaunchServices named it as the new Music's parent). So after any "Stopped"
/// notification nothing touches Music for `quitWindow`; if Music has exited
/// by then, the process check answers without an Apple Event.
@MainActor
public final class MusicMonitor {
    public enum Trigger: String, Sendable {
        case start, notification, launch, terminate, wake, poll, command
    }

    public var onSnapshot: ((MusicSnapshot, Trigger) -> Void)?

    public var debounce: Duration = .milliseconds(150)
    /// How long to leave Music alone after it reports "Stopped".
    public var quitWindow: Duration = .seconds(2)
    /// How long to leave Music alone after NSWorkspace reports it launched.
    public var launchSettle: Duration = .seconds(3)
    /// Poll interval by the last state seen.
    public var pollIntervals: [PlaybackState: Duration] = [
        .playing: .seconds(2), .paused: .seconds(5), .stopped: .seconds(5),
        .notRunning: .seconds(5), .automationDenied: .seconds(10), .error: .seconds(3),
    ]

    public private(set) var notificationsReceived = 0
    public private(set) var lastState: PlaybackState?

    private let controller: MusicController
    private let isLaunching: () -> Bool
    private var launchRetry: Task<Void, Never>?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var pollTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var reading = false
    private var pending: Trigger?
    private var holdUntil: ContinuousClock.Instant?
    private var heldTrigger: Trigger?
    private var holdTask: Task<Void, Never>?

    public init(controller: MusicController, isLaunching: @escaping () -> Bool = MusicController.isMusicLaunching) {
        self.controller = controller
        self.isLaunching = isLaunching
    }

    public func start() {
        guard observers.isEmpty else { return }
        let distributed = DistributedNotificationCenter.default()
        observers.append((distributed, distributed.addObserver(
            forName: Notification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main
        ) { [weak self] note in
            let state = note.userInfo?["Player State"] as? String
            MainActor.assumeIsolated { self?.playerInfoArrived(playerState: state) }
        }))

        let workspace = NSWorkspace.shared.notificationCenter
        let lifecycle: [(Notification.Name, Trigger)] = [
            (NSWorkspace.didLaunchApplicationNotification, .launch),
            (NSWorkspace.didTerminateApplicationNotification, .terminate),
        ]
        for (name, trigger) in lifecycle {
            observers.append((workspace, workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == MusicController.bundleID else { return }
                MainActor.assumeIsolated { self?.requestRead(trigger) }
            }))
        }
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.requestRead(.wake) }
        }))

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = self?.currentPollInterval ?? .seconds(5)
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                self?.requestRead(.poll)
            }
        }
        requestRead(.start)
    }

    public func stop() {
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        pollTask?.cancel()
        debounceTask?.cancel()
        holdTask?.cancel()
        launchRetry?.cancel()
        pollTask = nil
        debounceTask = nil
        holdTask = nil
        launchRetry = nil
    }

    /// True while Music may be quitting. Callers about to send it a command
    /// should `waitOutQuitWindow()` first.
    public var isHolding: Bool {
        holdUntil.map { ContinuousClock.now < $0 } ?? false
    }

    public func waitOutQuitWindow() async {
        while let until = holdUntil, ContinuousClock.now < until {
            try? await Task.sleep(until: until, clock: .continuous)
        }
    }

    /// Reads now, or as soon as the read in progress finishes, or once a quit
    /// or launch window has passed.
    public func requestRead(_ trigger: Trigger) {
        switch trigger {
        case .terminate:
            // Music has exited; the process check answers without events.
            endHold()
        case .launch:
            // NSWorkspace says "launched" before Music answers Apple Events: a
            // read at that moment timed out after 3 s on macOS 27.0.1. A
            // relaunched Music has nothing loaded, so there is no hurry.
            startHold(for: launchSettle, trigger: .launch)
            return
        default:
            if isHolding {
                heldTrigger = heldTrigger ?? trigger
                return
            }
        }
        beginRead(trigger)
    }

    private func beginRead(_ trigger: Trigger) {
        if reading {
            pending = trigger
            return
        }
        if isLaunching() {
            // Ask again shortly rather than block on a Music that isn't up yet.
            launchRetry?.cancel()
            launchRetry = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                self?.beginRead(trigger)
            }
            return
        }
        reading = true
        Task { await self.readUntilSettled(trigger) }
    }

    /// One read, outside the coalescing. For callers that need the result.
    public func read(_ trigger: Trigger) async -> MusicSnapshot {
        if trigger != .launch, trigger != .terminate { await waitOutQuitWindow() }
        let snapshot = controller.snapshot()
        lastState = snapshot.state
        return snapshot
    }

    private var currentPollInterval: Duration {
        lastState.flatMap { pollIntervals[$0] } ?? .seconds(2)
    }

    /// Internal so tests can drive it without posting a system-wide
    /// notification that other Music listeners would also receive.
    func playerInfoArrived(playerState: String?) {
        notificationsReceived += 1
        if playerState == "Stopped" { startHold(for: quitWindow, trigger: nil) }
        debounceTask?.cancel()
        let delay = debounce
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.requestRead(.notification)
        }
    }

    private func startHold(for duration: Duration, trigger: Trigger?) {
        let until = ContinuousClock.now.advanced(by: duration)
        holdUntil = until
        if let trigger { heldTrigger = trigger }
        holdTask?.cancel()
        holdTask = Task { [weak self] in
            try? await Task.sleep(until: until, clock: .continuous)
            guard !Task.isCancelled, let self else { return }
            let trigger = heldTrigger ?? .notification
            endHold()
            beginRead(trigger)
        }
    }

    private func endHold() {
        holdUntil = nil
        heldTrigger = nil
        holdTask?.cancel()
        holdTask = nil
    }

    private func readUntilSettled(_ first: Trigger) async {
        var next: Trigger? = first
        while let trigger = next {
            pending = nil
            let snapshot = await read(trigger)
            onSnapshot?(snapshot, trigger)
            next = pending
        }
        reading = false
    }
}
