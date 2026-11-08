//  MusicProbe.swift
//  Music StandBy — macOS spike
//
//  ⚠️  NOT COMPILED. The machine this was written on has damaged Command Line
//  Tools (`swiftc` fails with "redefinition of module 'SwiftBridging'") and no
//  Xcode, so this file has never been built. The *technique* it uses is the one
//  verified by `musicprobe.sh`, which did run successfully — see FINDINGS.md.
//
//  Drop this file into a SwiftUI menu-bar app and it should need nothing else:
//  no ScriptingBridge headers, no generated glue, no third-party package.
//
//      let probe = MusicProbe()
//      probe.onChange = { snapshot in /* publish to your model */ }
//      probe.start()
//
//  Permissions: see README.md. The host app needs NSAppleEventsUsageDescription,
//  and, if sandboxed, an apple-events entitlement scoped to com.apple.Music.

import AppKit
import Foundation

// MARK: - Model

public enum PlayerState: String, Codable, Sendable {
    case stopped, playing, paused
}

public struct MusicTrack: Codable, Equatable, Sendable {
    public var title: String
    public var artist: String
    public var album: String
    public var albumArtist: String?
    public var duration: TimeInterval
    /// Stable within one library. Present on Apple Music catalogue tracks too.
    public var persistentID: String?
    public var databaseID: Int?
    /// AppleScript class: "file track", "URL track", "shared track", "audio CD track".
    public var trackClass: String?
    public var artworkCount: Int
}

public struct MusicSnapshot: Codable, Equatable, Sendable {
    public var isRunning: Bool
    public var state: PlayerState
    public var position: TimeInterval
    public var capturedAt: Date
    public var track: MusicTrack?

    public var isPlaying: Bool { state == .playing }

    /// What a listener cares about. Deliberately excludes `position`, so that
    /// ordinary progress does not read as a change.
    var changeKey: String {
        [isRunning.description, state.rawValue,
         track?.persistentID ?? "", track?.title ?? "",
         track?.artist ?? "", track?.album ?? ""].joined(separator: "|")
    }

    static let notRunning = MusicSnapshot(
        isRunning: false, state: .stopped, position: 0, capturedAt: Date(), track: nil)
}

// MARK: - Probe

public final class MusicProbe {

    /// Called on `queue` whenever the snapshot meaningfully changes.
    public var onChange: ((MusicSnapshot) -> Void)?

    /// Fallback poll interval. Only used while playing, to keep `position`
    /// honest; track changes arrive by notification.
    public var pollInterval: TimeInterval = 2.0

    /// NSAppleScript is not thread-safe, so every execution is funnelled here.
    private let queue = DispatchQueue(label: "au.ivystreet.musicstandby.musicprobe")
    private var timer: DispatchSourceTimer?
    private var lastKey: String?
    private var compiled: NSAppleScript?

    public init() {}

    // MARK: Lifecycle

    public func start() {
        // Music.app posts this on every play, pause and track change. The
        // userInfo carries metadata too, but it is not documented, so we ignore
        // it and re-read the authoritative state instead.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.Music.playerInfo"),
            object: nil, queue: nil
        ) { [weak self] _ in
            self?.refresh()
        }
        startTimer()
        refresh()
    }

    public func stop() {
        DistributedNotificationCenter.default().removeObserver(self)
        timer?.cancel()
        timer = nil
    }

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        t.setEventHandler { [weak self] in self?.refresh() }
        t.resume()
        timer = t
    }

    // MARK: Reading

    /// Current state. Returns `.notRunning` without launching Music.app.
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

    private func readSnapshot() -> MusicSnapshot {
        guard isMusicRunning() else { return .notRunning }
        guard let raw = runScript() else { return .notRunning }
        return parse(raw)
    }

    /// Asked of the running-application list, not of Music, so this never
    /// launches Music.app as a side effect.
    private func isMusicRunning() -> Bool {
        !NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == "com.apple.Music" }.isEmpty
    }

    private func runScript() -> String? {
        if compiled == nil { compiled = NSAppleScript(source: Self.source) }
        var error: NSDictionary?
        let result = compiled?.executeAndReturnError(&error)
        if let error {
            // -1743 is errAEEventNotPermitted: Automation permission refused.
            NSLog("MusicProbe: AppleScript failed: \(error)")
            return nil
        }
        return result?.stringValue
    }

    private func parse(_ raw: String) -> MusicSnapshot {
        var f = raw.components(separatedBy: "\u{1f}")
        while f.count < 11 { f.append("") }
        let state = PlayerState(rawValue: f[0]) ?? .stopped
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
        return MusicSnapshot(
            isRunning: true, state: state,
            position: Double(f[1]) ?? 0, capturedAt: Date(), track: track)
    }

    // MARK: Commands
    //
    // All four are no-ops when Music.app is not running. Each returns the
    // snapshot taken shortly afterwards, so a caller can acknowledge the
    // command with real state rather than an optimistic guess.

    @discardableResult public func play() -> MusicSnapshot { command("play") }
    @discardableResult public func pause() -> MusicSnapshot { command("pause") }
    @discardableResult public func next() -> MusicSnapshot { command("next track") }
    @discardableResult public func previous() -> MusicSnapshot { command("previous track") }

    private func command(_ verb: String) -> MusicSnapshot {
        queue.sync {
            guard isMusicRunning() else { return .notRunning }
            var error: NSDictionary?
            NSAppleScript(source: "tell application \"Music\" to \(verb)")?
                .executeAndReturnError(&error)
            if let error { NSLog("MusicProbe: \(verb) failed: \(error)") }
            // Music needs a beat to settle before it reports the new state.
            Thread.sleep(forTimeInterval: 0.4)
            return readSnapshot()
        }
    }

    // MARK: The script
    //
    // One round trip per refresh. Every optional property is wrapped, because
    // `current track` throws when stopped and several properties are absent on
    // catalogue tracks. Field order must match `parse(_:)`.

    private static let source = """
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
}
