//  MusicProbe.swift
//  Music StandBy — macOS spike
//
//  ⚠️  UNCOMPILED AND UNVERIFIED. No Xcode on the authoring Mac, and `swiftc`
//  fails on the damaged Command Line Tools. Nothing in this file has been built
//  or run. The TECHNIQUES are the ones verified by `musicprobe.sh`,
//  `artwork.sh` and `notifywatch.applescript` (see FINDINGS.md), but a working
//  shell script is not evidence that this Swift works. Build it, then test every
//  path below before relying on it. MAC-HANDOVER.md has the checklist.
//
//  Drop into a SwiftUI menu-bar app. No dependencies beyond the SDK.
//
//      let probe = MusicProbe()
//      probe.onChange = { snapshot in /* hop to the main actor, publish */ }
//      probe.start()
//
//  Host app needs NSAppleEventsUsageDescription and, if sandboxed,
//  com.apple.security.automation.apple-events plus a temporary-exception
//  apple-events entitlement for com.apple.Music.

import AppKit
import CryptoKit
import Foundation

// MARK: - Model

/// Mirrors the states `musicprobe.sh` reports. Raw values match its JSON.
public enum PlayerState: String, Codable, Sendable {
    case notRunning = "not_running"
    case stopped
    case paused
    case playing
    /// AppleScript error -1743: Automation permission refused. Permanent until
    /// the user changes it in System Settings → Privacy & Security → Automation.
    case automationDenied = "automation_denied"
    /// Any other AppleScript failure while Music is running.
    case error
}

public struct MusicTrack: Codable, Equatable, Sendable {
    public var title: String
    public var artist: String
    public var album: String
    public var albumArtist: String?
    public var duration: TimeInterval
    /// Stable within one Music.app run. Fall back to title|artist|album|duration
    /// across restarts (FINDINGS.md, lifecycle).
    public var persistentID: String?
    public var databaseID: Int?
    /// "file track", "URL track" (streamed catalogue), "shared track", …
    public var trackClass: String?
    public var artworkCount: Int

    /// Identity that survives a Music restart, for when persistentID can't.
    public var fallbackKey: String {
        "\(title)|\(artist)|\(album)|\(Int(duration.rounded()))"
    }
}

public struct MusicSnapshot: Codable, Equatable, Sendable {
    public var state: PlayerState
    public var position: TimeInterval
    public var capturedAt: Date
    public var track: MusicTrack?
    /// AppleScript error text for `.automationDenied` and `.error`.
    public var errorDetail: String?

    public var isRunning: Bool { state != .notRunning }
    public var isPlaying: Bool { state == .playing }

    /// What a listener cares about. Excludes `position`, so progress is not a change.
    var changeKey: String {
        [state.rawValue, track?.persistentID ?? "", track?.title ?? "",
         track?.artist ?? "", track?.album ?? ""].joined(separator: "|")
    }

    static func notRunning() -> MusicSnapshot {
        MusicSnapshot(state: .notRunning, position: 0, capturedAt: Date(), track: nil, errorDetail: nil)
    }

    static func failure(_ state: PlayerState, _ detail: String) -> MusicSnapshot {
        MusicSnapshot(state: state, position: 0, capturedAt: Date(), track: nil, errorDetail: detail)
    }
}

public struct MusicArtwork: Sendable {
    public var data: Data
    /// "png", "jpeg" or "unknown", from the bytes' magic number.
    public var format: String
    /// Hex SHA-256 of `data`: the relay's artworkID and cache key.
    public var sha256: String
}

// MARK: - Probe

public final class MusicProbe {

    public static let bundleID = "com.apple.Music"

    /// Called on `queue` when the snapshot meaningfully changes.
    public var onChange: ((MusicSnapshot) -> Void)?

    /// Fallback poll. Keeps `position` honest and catches missed notifications.
    public var pollInterval: TimeInterval = 2.0

    /// NSAppleScript is not thread-safe: every execution goes through here.
    private let queue = DispatchQueue(label: "au.ivystreet.musicstandby.musicprobe")
    private var timer: DispatchSourceTimer?
    private var lastKey: String?
    private var compiledSnapshot: NSAppleScript?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    public init() {}

    // MARK: Lifecycle

    /// Three signals, because each misses something (FINDINGS.md):
    /// - `com.apple.Music.playerInfo` — play, pause, track change. Fires with only
    ///   "Stopped" on quit, which is ambiguous, and NOT AT ALL on launch.
    /// - NSWorkspace launch / terminate — the only reliable app-lifecycle signal.
    /// - A timer — position, and anything missed.
    public func start() {
        let distributed = DistributedNotificationCenter.default()
        observers.append((distributed, distributed.addObserver(
            forName: Notification.Name("com.apple.Music.playerInfo"),
            object: nil, queue: nil
        ) { [weak self] _ in
            // Trigger only. The payload has no persistent ID or position, often
            // arrives twice, and its Total Time wobbles. Re-read instead.
            self?.refresh()
        }))

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            observers.append((workspace, workspace.addObserver(
                forName: name, object: nil, queue: nil
            ) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == MusicProbe.bundleID else { return }
                // A relaunched Music has no current track (verified). Report what
                // is true and let the relay end the session; do not try to restore.
                self?.refresh()
            }))
        }

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        t.setEventHandler { [weak self] in self?.refresh() }
        t.resume()
        timer = t
        refresh()
    }

    public func stop() {
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        timer?.cancel()
        timer = nil
    }

    // MARK: Reading

    /// Current state. Never launches Music.app.
    public func snapshot() -> MusicSnapshot {
        queue.sync { readSnapshot() }
    }

    private func refresh() {
        queue.async {
            let snap = self.readSnapshot()
            guard snap.changeKey != self.lastKey else { return }
            self.lastKey = snap.changeKey
            self.onChange?(snap)
        }
    }

    /// Guard 1 of 2: a process check. Sends no Apple Events, so it cannot launch
    /// Music and cannot block on it.
    public static func isMusicRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    private func readSnapshot() -> MusicSnapshot {
        guard Self.isMusicRunning() else { return .notRunning() }
        if compiledSnapshot == nil { compiledSnapshot = NSAppleScript(source: Self.snapshotSource) }
        switch Self.execute(compiledSnapshot) {
        case .notRunning: return .notRunning()
        case .failure(let state, let detail): return .failure(state, detail)
        case .success(let descriptor):
            guard let raw = descriptor.stringValue else { return .failure(.error, "non-text result") }
            return Self.parse(raw)
        }
    }

    private static func parse(_ raw: String) -> MusicSnapshot {
        var f = raw.components(separatedBy: "\u{1f}")
        while f.count < 11 { f.append("") }
        let state: PlayerState = ["playing": .playing, "paused": .paused][f[0]] ?? .stopped
        var track: MusicTrack?
        if !f[2].isEmpty {
            track = MusicTrack(
                title: f[2], artist: f[3], album: f[4],
                albumArtist: f[5].isEmpty ? nil : f[5],
                duration: Double(f[6]) ?? 0,
                persistentID: f[7].isEmpty ? nil : f[7],
                databaseID: Int(f[8]),
                trackClass: f[9].isEmpty ? nil : f[9],
                artworkCount: Int(f[10]) ?? 0)
        }
        return MusicSnapshot(state: state, position: Double(f[1]) ?? 0,
                             capturedAt: Date(), track: track, errorDetail: nil)
    }

    // MARK: Artwork

    /// Current track's first artwork as raw bytes, hashed. nil if Music is not
    /// running, there is no track, or there is no artwork.
    ///
    /// UNVERIFIED in Swift. The shell version proved `raw data of artwork 1`
    /// returns real PNG bytes, byte-stable across calls. What is NOT proven is that
    /// `NSAppleEventDescriptor.data` hands back those same bytes unwrapped: the
    /// descriptor's type may be 'PNGf', 'JPEG' or 'tdta'. Compare the SHA-256 with
    /// `./artwork.sh info` for the same track on first build.
    public func artwork() -> MusicArtwork? {
        queue.sync {
            guard Self.isMusicRunning() else { return nil }
            guard case .success(let d) = Self.execute(NSAppleScript(source: Self.artworkSource)),
                  !d.data.isEmpty else { return nil }
            let bytes = d.data
            let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let format: String
            if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { format = "png" }
            else if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { format = "jpeg" }
            else { format = "unknown" }
            return MusicArtwork(data: bytes, format: format, sha256: hash)
        }
    }

    // MARK: Commands
    //
    // Interface unchanged. Each returns the snapshot taken 0.4 s later (verified
    // long enough in the shell probe). If Music is not running they return
    // `.notRunning` and do NOT launch it.

    @discardableResult public func play() -> MusicSnapshot { command("play") }
    @discardableResult public func pause() -> MusicSnapshot { command("pause") }
    @discardableResult public func playPause() -> MusicSnapshot { command("playpause") }
    @discardableResult public func next() -> MusicSnapshot { command("next track") }
    @discardableResult public func previous() -> MusicSnapshot { command("previous track") }

    private func command(_ verb: String) -> MusicSnapshot {
        queue.sync {
            guard Self.isMusicRunning() else { return .notRunning() }
            let source = """
            \(Self.guardLine)
            tell application "Music" to \(verb)
            return "ok"
            """
            switch Self.execute(NSAppleScript(source: source)) {
            case .notRunning: return .notRunning()
            case .failure(let state, let detail): return .failure(state, detail)
            case .success: break
            }
            Thread.sleep(forTimeInterval: 0.4)
            return readSnapshot()
        }
    }

    // MARK: Execution

    private enum Outcome {
        case success(NSAppleEventDescriptor)
        case notRunning
        case failure(PlayerState, String)
    }

    /// Runs a script and classifies the result. -1743 is errAEEventNotPermitted.
    private static func execute(_ script: NSAppleScript?) -> Outcome {
        guard let script else { return .failure(.error, "script did not compile") }
        var info: NSDictionary?
        let result = script.executeAndReturnError(&info)
        if let info {
            let number = info[NSAppleScript.errorNumber] as? Int ?? 0
            let message = info[NSAppleScript.errorMessage] as? String ?? "\(info)"
            return .failure(number == -1743 ? .automationDenied : .error, message)
        }
        if result.stringValue == "NOT_RUNNING" { return .notRunning }
        return .success(result)
    }

    // MARK: Scripts
    //
    // Guard 2 of 2: Music may quit between the process check and the Apple
    // Event, and `tell application "Music"` would relaunch it. `is running` does
    // not launch the target (verified on a closed app in the shell probe).

    private static let guardLine =
        #"if not (application id "com.apple.Music" is running) then return "NOT_RUNNING""#

    /// Same script as musicprobe.sh. Field order must match `parse(_:)`.
    private static let snapshotSource = """
    \(guardLine)
    set US to (ASCII character 31)
    tell application "Music"
    \tset playerState to (player state as text)
    \tset pos to "0"
    \ttry
    \t\tset pos to (player position as text)
    \tend try
    \tset f to {playerState, pos, "", "", "", "", "0", "", "0", "", "0"}
    \ttry
    \t\tset t to current track
    \t\tset item 3 of f to (name of t)
    \t\tset item 4 of f to (artist of t)
    \t\tset item 5 of f to (album of t)
    \t\ttry
    \t\t\tset item 6 of f to (album artist of t)
    \t\tend try
    \t\tset item 7 of f to (duration of t as text)
    \t\ttry
    \t\t\tset item 8 of f to (persistent ID of t)
    \t\tend try
    \t\ttry
    \t\t\tset item 9 of f to (database ID of t as text)
    \t\tend try
    \t\tset item 10 of f to (class of t as text)
    \t\ttry
    \t\t\tset item 11 of f to (count of artworks of t as text)
    \t\tend try
    \tend try
    \tset AppleScript's text item delimiters to US
    \tset out to f as text
    \tset AppleScript's text item delimiters to ""
    \treturn out
    end tell
    """

    /// Returns the raw artwork data; empty result means no track or no artwork.
    private static let artworkSource = """
    \(guardLine)
    tell application "Music"
    \ttry
    \t\tset t to current track
    \t\tif (count of artworks of t) is 0 then return ""
    \t\treturn raw data of artwork 1 of t
    \ton error
    \t\treturn ""
    \tend try
    end tell
    """
}
