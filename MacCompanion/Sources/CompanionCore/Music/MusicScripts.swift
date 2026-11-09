import Foundation

/// A playback command Music.app understands. A superset of the wire's
/// `CommandKind`: the menu also offers a play/pause toggle.
public enum MusicCommand: String, Sendable, CaseIterable {
    case play, pause, playPause, next, previous

    /// The AppleScript verb, as verified in the spike's `selftest.sh`.
    var verb: String {
        switch self {
        case .play: "play"
        case .pause: "pause"
        case .playPause: "playpause"
        case .next: "next track"
        case .previous: "previous track"
        }
    }
}

/// The only scripts the companion ever runs. `RawEventRunner` sends each as
/// raw Apple Events; the AppleScript source is the reference they match.
public enum MusicScript: Hashable, Sendable {
    case snapshot
    case artwork
    case command(MusicCommand)

    /// Guard 2 of 2. Music may quit between the process check and the Apple
    /// Event, and `tell application "Music"` would relaunch it. `is running`
    /// does not launch the target (verified in the spike).
    static let guardLine = #"if not (application id "com.apple.Music" is running) then return "NOT_RUNNING""#

    var source: String {
        switch self {
        case .snapshot: Self.snapshotSource
        case .artwork: Self.artworkSource
        case .command(let command):
            """
            \(Self.guardLine)
            with timeout of 3 seconds
            \ttell application "Music" to \(command.verb)
            end timeout
            return "ok"
            """
        }
    }

    /// The tested `musicprobe.sh` fields and order, with two changes measured
    /// on macOS 27.0.1. `properties of current track` fetches every track field
    /// in one Apple Event, where reading each property was eleven events and
    /// 100–430 ms on the main thread; and a timeout, because without one a
    /// hung Music blocks for AppleScript's default two minutes (the spike saw a
    /// 19.8 s call while Music relaunched). Field order must match
    /// `SnapshotParser`.
    private static let snapshotSource = """
    \(guardLine)
    set US to (ASCII character 31)
    with timeout of 3 seconds
    \ttell application "Music"
    \t\tset playerState to (player state as text)
    \t\tset pos to "0"
    \t\ttry
    \t\t\tset pos to (player position as text)
    \t\tend try
    \t\tset f to {playerState, pos, "", "", "", "", "0", "", "0", "", "0"}
    \t\ttry
    \t\t\tset p to properties of current track
    \t\t\tset item 3 of f to (name of p)
    \t\t\tset item 4 of f to (artist of p)
    \t\t\tset item 5 of f to (album of p)
    \t\t\ttry
    \t\t\t\tset item 6 of f to (album artist of p)
    \t\t\tend try
    \t\t\tset item 7 of f to (duration of p as text)
    \t\t\ttry
    \t\t\t\tset item 8 of f to (persistent ID of p)
    \t\t\tend try
    \t\t\ttry
    \t\t\t\tset item 9 of f to (database ID of p as text)
    \t\t\tend try
    \t\t\tset item 10 of f to (class of p as text)
    \t\t\ttry
    \t\t\t\tset item 11 of f to (count of artworks of current track as text)
    \t\t\tend try
    \t\tend try
    \t\tset AppleScript's text item delimiters to US
    \t\tset out to f as text
    \t\tset AppleScript's text item delimiters to ""
    \t\treturn out
    \tend tell
    end timeout
    """

    /// Returns "NO_TRACK", `{pid}` when the track has no artwork, or
    /// `{pid, raw data}`. The persistent ID comes back with the bytes so a skip
    /// between the snapshot and this call can't pin the wrong art on a track.
    /// Each value is pulled into a local first: a list of live references can't
    /// be coerced inside a tell block (-1700, found in the spike).
    private static let artworkSource = """
    \(guardLine)
    with timeout of 5 seconds
    \ttell application "Music"
    \t\ttry
    \t\t\tset t to current track
    \t\ton error
    \t\t\treturn "NO_TRACK"
    \t\tend try
    \t\tset pid to ""
    \t\ttry
    \t\t\tset pid to (persistent ID of t)
    \t\tend try
    \t\tif (count of artworks of t) is 0 then return {pid}
    \t\tset d to raw data of artwork 1 of t
    \t\treturn {pid, d}
    \tend tell
    end timeout
    """
}

/// A script's result as plain values, so it can cross actors and be faked.
public indirect enum ScriptValue: Equatable, Sendable {
    case text(String)
    /// Bytes plus the Apple Event descriptor type, e.g. `PNGf` or `tdta`.
    case data(Data, type: String)
    case list([ScriptValue])
}

public enum ScriptOutput: Equatable, Sendable {
    /// Music wasn't running, so nothing was sent; or, for `RawEventRunner`,
    /// the process the events were addressed to quit before answering.
    /// Either way nothing launched Music.
    case notRunning
    case value(ScriptValue)
    /// `NSAppleScript.errorNumber` and `errorMessage`.
    case failure(code: Int, message: String)
}

/// Runs `MusicScript`s. `RawEventRunner` is the real one, `AppleScriptRunner`
/// the reference it is checked against, and tests use a fake. `MusicController`
/// calls `run` on its own serial queue, never the main thread.
public protocol MusicScriptRunning: Sendable {
    func run(_ script: MusicScript) -> ScriptOutput
}

/// Runs scripts with NSAppleScript, **on the main thread only**. No longer
/// used by `MusicController`: `msbctl compare` runs it beside
/// `RawEventRunner` to check the two return the same output.
///
/// Apple documents NSAppleScript as main-thread only, and on macOS 27.0.1 it
/// means it: measured against Music, a one-event script took 5–30 ms on the
/// main thread and 8–158 s on a background queue or thread, and an actor on a
/// serial-queue executor hung. `run` checks, which is why `@unchecked
/// Sendable` holds. Its `tell application "Music"` addresses Music by name,
/// which relaunches a quitting Music.
public final class AppleScriptRunner: MusicScriptRunning, @unchecked Sendable {
    private var compiled: [MusicScript: NSAppleScript] = [:]

    public init() {}

    public func run(_ script: MusicScript) -> ScriptOutput {
        dispatchPrecondition(condition: .onQueue(.main))
        var info: NSDictionary?
        let apple: NSAppleScript
        if let cached = compiled[script] {
            apple = cached
        } else {
            guard let fresh = NSAppleScript(source: script.source) else {
                return .failure(code: 0, message: "script could not be created")
            }
            // Compiled once, and only after the process check found Music
            // running. Whether compiling alone can launch Music is unproven.
            guard fresh.compileAndReturnError(&info) else { return Self.failure(info) }
            compiled[script] = fresh
            apple = fresh
        }
        let result = apple.executeAndReturnError(&info)
        if let info { return Self.failure(info) }
        let value = Self.value(of: result)
        if value == .text("NOT_RUNNING") { return .notRunning }
        return .value(value)
    }

    private static func failure(_ info: NSDictionary?) -> ScriptOutput {
        let code = (info?[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
        let message = info?[NSAppleScript.errorMessage] as? String ?? "AppleScript failed"
        return .failure(code: code, message: message)
    }

    static func value(of descriptor: NSAppleEventDescriptor) -> ScriptValue {
        let type = descriptor.descriptorType
        if type == typeAEList {
            let count = descriptor.numberOfItems
            return .list(count == 0 ? [] : (1...count).compactMap { descriptor.atIndex($0).map(value(of:)) })
        }
        if [typeUnicodeText, typeUTF8Text, typeChar, typeUTF16ExternalRepresentation].contains(type) {
            return .text(descriptor.stringValue ?? "")
        }
        return .data(descriptor.data, type: fourCharCode(type))
    }

    static func fourCharCode(_ code: DescType) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
