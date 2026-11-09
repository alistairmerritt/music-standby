import AppKit
import Foundation
import StandByProtocol

/// Talks to Music.app. Never launches it.
///
/// Two guards, both from the spike: a process check before any Apple Event
/// (no events sent, so it cannot launch Music or block on it), then an
/// in-script `is running` check for the moment between that and the event.
///
/// Main-actor bound, because NSAppleScript only works properly on the main
/// thread (see `AppleScriptRunner`). Each call blocks the main thread for its
/// Apple Events: a snapshot is four events, typically 30–100 ms; a command is
/// one. Timeouts cap a hung Music at 3 s (5 s for artwork).
@MainActor
public final class MusicController {
    public nonisolated static let bundleID = "com.apple.Music"

    private let runner: any MusicScriptRunning
    private let isRunning: () -> Bool
    private let now: () -> Date

    /// Scripts actually executed. Stays put while Music is closed.
    public private(set) var scriptsRun = 0
    /// Reads and commands answered by the process check alone.
    public private(set) var skippedWhileClosed = 0

    public init(runner: any MusicScriptRunning = AppleScriptRunner(),
                isRunning: @escaping () -> Bool = MusicController.isMusicRunning,
                now: @escaping () -> Date = { Date() }) {
        self.runner = runner
        self.isRunning = isRunning
        self.now = now
    }

    /// Guard 1 of 2. Sends no Apple Events.
    public nonisolated static func isMusicRunning() -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains { !$0.isTerminated }
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
