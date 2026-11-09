import AppKit
import Foundation
import StandByProtocol

/// Talks to Music.app. Never launches it.
///
/// Two guards: a process check before any Apple Event (no events sent, so it
/// cannot launch Music or block on it), then the runner's own. The default
/// runner, `RawEventRunner`, addresses every event to Music's process id, so
/// an event that reaches a Music that has since quit fails instead of
/// relaunching it.
///
/// An actor on its own serial queue. Each Apple Event blocks the thread that
/// sends it until Music answers or the timeout passes (3 s, 5 s for artwork),
/// so the controller keeps that off the main thread, where the AppleScript
/// version blocked the UI for 30–620 ms a read, and off Swift's cooperative
/// pool, which has one thread per core. A snapshot is four events, 22–33 ms
/// measured; a command is one. Calls are serialized, so reads never overlap
/// and their `capturedAt` order is the order Music answered them.
public actor MusicController {
    public static let bundleID = "com.apple.Music"

    private let queue = DispatchSerialQueue(label: "com.alistairmerritt.MusicStandBy.music", qos: .userInitiated)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let runner: any MusicScriptRunning
    private let isRunning: @Sendable () -> Bool
    private let now: @Sendable () -> Date

    /// Scripts actually executed. Stays put while Music is closed.
    public private(set) var scriptsRun = 0
    /// Reads and commands answered by the process check alone.
    public private(set) var skippedWhileClosed = 0

    public init(runner: any MusicScriptRunning = RawEventRunner(),
                isRunning: @escaping @Sendable () -> Bool = MusicController.isMusicRunning,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.runner = runner
        self.isRunning = isRunning
        self.now = now
    }

    /// Guard 1 of 2. Sends no Apple Events. See `MusicProcess` for why this
    /// isn't NSRunningApplication alone.
    public static func isMusicRunning() -> Bool {
        MusicProcess.shared.pid() != nil
    }

    /// Running but not ready for Apple Events: spawned less than
    /// `MusicProcess.answerDelay` ago, or not finished launching. An event sent
    /// then waits for Music to come up, and one sent 0.1 s after spawn timed
    /// out at 3 s on macOS 27.0.1. NSWorkspace's launch notification arrives
    /// about 0.85 s after spawn, so this also covers the gap before it. Sends
    /// no Apple Events.
    public static func isMusicLaunching() -> Bool {
        guard let pid = MusicProcess.shared.pid() else { return false }
        if let age = MusicProcess.age(of: pid), age < MusicProcess.answerDelay { return true }
        return NSRunningApplication(processIdentifier: pid).map { !$0.isFinishedLaunching } ?? false
    }

    // MARK: Reading

    public func snapshot() -> MusicSnapshot {
        guard isRunning() else {
            skippedWhileClosed += 1
            return .notRunning(at: now())
        }
        let start = now()
        let output = run(.snapshot)
        let end = now()
        switch output {
        case .notRunning:
            return .notRunning(at: end)
        case .failure(let code, let message):
            return failureSnapshot(code: code, message: message, at: end)
        case .value(.text(let raw)):
            // Position was read somewhere inside the round trip: take the middle.
            return SnapshotParser.parse(raw, capturedAt: start.addingTimeInterval(end.timeIntervalSince(start) / 2))
        case .value(let other):
            return .failure(.error, "unexpected snapshot result: \(other)", at: end)
        }
    }

    public enum ArtworkResult: Equatable, Sendable {
        /// Raw bytes exactly as Music returned them.
        case image(Data, persistentID: String?, descriptorType: String)
        case noArtwork(persistentID: String?)
        case noTrack
        case notRunning
        case failed(PlaybackState, String)
    }

    public func artwork() -> ArtworkResult {
        guard isRunning() else {
            skippedWhileClosed += 1
            return .notRunning
        }
        switch run(.artwork) {
        case .notRunning: return .notRunning
        case .failure(let code, let message):
            let failure = failureSnapshot(code: code, message: message, at: now())
            return failure.state == .notRunning ? .notRunning : .failed(failure.state, failure.detail ?? message)
        case .value(.text("NO_TRACK")): return .noTrack
        case .value(.list(let items)):
            let pid: String? = if case .text(let text)? = items.first, !text.isEmpty { text } else { nil }
            guard items.count >= 2 else { return .noArtwork(persistentID: pid) }
            guard case .data(let bytes, let type) = items[1], !bytes.isEmpty else {
                return .failed(.error, "artwork was not data: \(items[1])")
            }
            return .image(bytes, persistentID: pid, descriptorType: type)
        case .value(let other):
            return .failed(.error, "unexpected artwork result: \(other)")
        }
    }

    // MARK: Commands

    public enum CommandOutcome: Equatable, Sendable {
        case performed
        case notRunning
        case automationDenied(String)
        case failed(String)
    }

    /// Sends one command. Does not wait for Music to settle or re-read it.
    public func perform(_ command: MusicCommand) -> CommandOutcome {
        guard isRunning() else {
            skippedWhileClosed += 1
            return .notRunning
        }
        switch run(.command(command)) {
        case .notRunning: return .notRunning
        case .value: return .performed
        case .failure(let code, let message):
            let failure = failureSnapshot(code: code, message: message, at: now())
            switch failure.state {
            case .notRunning: return .notRunning
            case .automationDenied: return .automationDenied(failure.detail ?? message)
            default: return .failed(failure.detail ?? message)
            }
        }
    }

    // MARK: Internals

    private func run(_ script: MusicScript) -> ScriptOutput {
        scriptsRun += 1
        return runner.run(script)
    }

    /// -1743 errAEEventNotPermitted and -1744 errAEEventWouldRequireUserConsent
    /// are permission problems. -600 procNotFound and -609 connectionInvalid mean
    /// Music went away mid-call, but only count as "not running" if the process
    /// check agrees. Everything else, including the -1712 timeout, is an error.
    /// A refused permission must never look like Music being closed.
    func failureSnapshot(code: Int, message: String, at date: Date) -> MusicSnapshot {
        switch code {
        case -1743, -1744: return .failure(.automationDenied, "\(message) (\(code))", at: date)
        case -600 where !isRunning(), -609 where !isRunning(): return .notRunning(at: date)
        default: return .failure(.error, "\(message) (\(code))", at: date)
        }
    }
}
