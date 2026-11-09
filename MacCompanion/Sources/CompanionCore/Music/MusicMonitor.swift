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
@MainActor
public final class MusicMonitor {
    public enum Trigger: String, Sendable {
        case start, notification, launch, terminate, wake, poll, command
    }

    public var onSnapshot: ((MusicSnapshot, Trigger) -> Void)?

    public var debounce: Duration = .milliseconds(150)
    /// Poll interval by the last state seen.
    public var pollIntervals: [PlaybackState: Duration] = [
        .playing: .seconds(2), .paused: .seconds(5), .stopped: .seconds(5),
        .notRunning: .seconds(5), .automationDenied: .seconds(10), .error: .seconds(3),
    ]

    public private(set) var notificationsReceived = 0
    public private(set) var lastState: PlaybackState?

    private let controller: MusicController
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var pollTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var reading = false
    private var pending: Trigger?

    public init(controller: MusicController) {
        self.controller = controller
    }

    public func start() {
        guard observers.isEmpty else { return }
        let distributed = DistributedNotificationCenter.default()
        observers.append((distributed, distributed.addObserver(
            forName: Notification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.playerInfoArrived() }
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
        pollTask = nil
        debounceTask = nil
    }

    /// Reads now, or as soon as the read in progress finishes.
    public func requestRead(_ trigger: Trigger) {
        if reading {
            pending = trigger
            return
        }
        reading = true
        Task { await self.readUntilSettled(trigger) }
    }

    /// One read, outside the coalescing. For callers that need the result.
    public func read(_ trigger: Trigger) async -> MusicSnapshot {
        let snapshot = await controller.snapshot()
        lastState = snapshot.state
        return snapshot
    }

    private var currentPollInterval: Duration {
        lastState.flatMap { pollIntervals[$0] } ?? .seconds(2)
    }

    private func playerInfoArrived() {
        notificationsReceived += 1
        debounceTask?.cancel()
        let delay = debounce
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.requestRead(.notification)
        }
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
