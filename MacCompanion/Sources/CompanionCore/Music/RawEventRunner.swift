import AppKit
import Foundation
import StandByProtocol

/// Runs `MusicScript`s as raw Apple Events, addressed to Music's **process
/// id**. This is the runner `MusicController` uses.
///
/// It replaced `AppleScriptRunner` because of two measurements on macOS 27.0.1
/// (STATUS.md, "Raw Apple Events"):
/// - `sendEvent` works on any thread. An event took 7–10 ms from a GCD queue,
///   a `Thread`, an actor and the cooperative pool, with the main thread
///   blocked. NSAppleScript took 8–158 s off the main thread.
/// - An event addressed by PID can't launch anything. If that process has
///   quit, the send fails. An event addressed by name, which
///   `tell application "Music"` sends, makes LaunchServices relaunch a
///   quitting Music.
///
/// It returns the same `ScriptOutput` as `AppleScriptRunner` for the same
/// Music state, down to AppleScript's text formatting of numbers, so
/// `SnapshotParser` and `MusicController` didn't change. Each script becomes
/// the same events in the same order, and the scripts' `try` blocks carry
/// over. An error **in Music's reply**, such as -1728 when nothing is loaded,
/// is ignored where the script ignored it. An error **sending**, such as -600,
/// -609, the -1712 timeout or the -1743 refusal, always fails the script. A
/// script's `try` would have hidden those. One exception: -600 or -609 from a
/// PID that no longer exists is `.notRunning`. That process quit, and
/// NSRunningApplication can take a moment to agree.
public struct RawEventRunner: MusicScriptRunning {
    /// One send's outcome. Internal so tests can fake Music's replies.
    enum Reply {
        /// The reply's direct object; nil for a command, which returns none.
        case result(NSAppleEventDescriptor?)
        /// Music answered with an error (`errn` in the reply).
        case musicError(code: Int, message: String)
        /// `sendEvent` itself failed: Music gone, timed out, or refused.
        case sendError(code: Int, message: String)
    }

    typealias Send = @Sendable (_ event: NSAppleEventDescriptor, _ timeout: TimeInterval) -> Reply

    private let processID: @Sendable () -> pid_t?
    private let processExists: @Sendable (pid_t) -> Bool
    private let send: Send

    public init() {
        self.init(processID: Self.musicProcessID, processExists: Self.processExists, send: Self.sendLive)
    }

    init(processID: @escaping @Sendable () -> pid_t?,
         processExists: @escaping @Sendable (pid_t) -> Bool = { _ in true },
         send: @escaping Send) {
        self.processID = processID
        self.processExists = processExists
        self.send = send
    }

    /// Music's PID. Sends no Apple Events; see `MusicProcess`.
    public static func musicProcessID() -> pid_t? {
        MusicProcess.shared.pid()
    }

    /// `kill(pid, 0)`: no signal is sent, only the check that the process exists.
    static func processExists(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno != ESRCH
    }

    public func run(_ script: MusicScript) -> ScriptOutput {
        // This replaces the scripts' `is running` guard. Every event in one
        // script goes to this one PID, so a Music relaunched part-way through
        // (the scrobbler does that within 2 s of a quit) can't answer half of
        // a snapshot. If the process has quit since, the send fails; it can't
        // start a new one.
        guard let pid = processID() else { return .notRunning }
        let music = Target(pid: pid, send: send)
        let output = switch script {
        case .snapshot: snapshot(music)
        case .artwork: artwork(music)
        case .command(let command): music.command(command)
        case .seek(let seconds): music.set(.property(Code.playerPosition), to: NSAppleEventDescriptor(double: seconds))
        case .setVolume(let level): music.set(.property(Code.soundVolume), to: NSAppleEventDescriptor(int32: Int32(level)))
        case .selectOutput(let id): selectOutput(music, id: id)
        }
        // Measured while Music quit: the event in flight failed with -609 once
        // the process had gone, then each one after with -600 in under 1 ms.
        if case .failure(let code, _) = output, code == -600 || code == -609, !processExists(pid) {
            return .notRunning
        }
        return output
    }

    // MARK: The three scripts

    /// `MusicScript.snapshotSource`, event for event: player state, player
    /// position, properties of current track, count of its artworks, then
    /// (11 November 2026) sound volume and the properties of every AirPlay
    /// device, one event for all of them.
    private func snapshot(_ music: Target) -> ScriptOutput {
        let timeout: TimeInterval = 3
        // `set playerState to (player state as text)`, outside any try.
        let state: String
        switch music.get(.property(Code.playerState), timeout: timeout) {
        case .result(let value): state = AppleScriptText.of(value)
        case .musicError(let code, let message), .sendError(let code, let message):
            return .failure(code: code, message: message)
        }
        var f = [state, "0", "", "", "", "", "0", "", "0", "", "0", "", ""]

        // `try: set pos to (player position as text)`. Stopped is `missing value`.
        switch music.get(.property(Code.playerPosition), timeout: timeout) {
        case .result(let value): f[1] = AppleScriptText.of(value)
        case .musicError: break
        case .sendError(let code, let message): return .failure(code: code, message: message)
        }

        // `try: set p to properties of current track`, then each field. A
        // missing field the script read outside its own `try` ends the block.
        let currentTrack = Specifier.property(Code.currentTrack)
        switch music.get(.property(Code.properties, of: currentTrack), timeout: timeout) {
        case .result(let record?) where record.descriptorType == typeAERecord:
            let fieldsComplete = Self.fill(&f, from: record)
            guard fieldsComplete else { break }
            switch music.count(Code.artwork, in: currentTrack, timeout: timeout) {
            case .result(let value): f[10] = AppleScriptText.of(value)
            case .musicError: break
            case .sendError(let code, let message): return .failure(code: code, message: message)
            }
        case .result, .musicError: break
        case .sendError(let code, let message): return .failure(code: code, message: message)
        }

        // `try: set item 12 of f to (sound volume as text)`
        switch music.get(.property(Code.soundVolume), timeout: timeout) {
        case .result(let value): f[11] = AppleScriptText.of(value)
        case .musicError: break
        case .sendError(let code, let message): return .failure(code: code, message: message)
        }

        // `try: repeat with d in AirPlay devices …`: one `properties of every
        // AirPlay device` event where the script sends five per device.
        switch outputs(music, timeout: timeout) {
        case .result(let devices): f[12] = devices.map(\.text).joined()
        case .musicError: break
        case .sendError(let code, let message): return .failure(code: code, message: message)
        }
        return .value(.text(f.joined(separator: SnapshotParser.separator)))
    }

    /// One AirPlay device as Music lists it, in the snapshot's text form.
    struct Output {
        var name: String
        var kind: String
        var selected: String
        var available: String
        var address: String

        var id: String { AudioOutput.makeID(networkAddress: address == "missing value" ? nil : address, name: name) }
        var text: String {
            [name, kind, selected, available, address].joined(separator: MusicScript.outputFieldSeparator) + MusicScript.outputSeparator
        }
    }

    enum OutputsReply {
        case result([Output])
        case musicError(code: Int, message: String)
        case sendError(code: Int, message: String)
    }

    /// `properties of every AirPlay device`: a list of records, read in Music's order.
    private func outputs(_ music: Target, timeout: TimeInterval) -> OutputsReply {
        switch music.get(.property(Code.properties, of: .every(Code.airPlayDevice)), timeout: timeout) {
        case .result(let list):
            guard let list, list.descriptorType == typeAEList || list.numberOfItems > 0 else { return .result([]) }
            var outputs: [Output] = []
            for index in stride(from: 1, through: list.numberOfItems, by: 1) {
                guard let item = list.atIndex(index) else { continue }
                let record = item.descriptorType == typeAERecord ? item : (item.coerce(toDescriptorType: typeAERecord) ?? item)
                func field(_ code: FourCharCode) -> String { AppleScriptText.of(record.forKeyword(code)) }
                outputs.append(Output(name: field(Code.name), kind: field(Code.kind), selected: field(Code.selected),
                                      available: field(Code.available), address: field(Code.networkAddress)))
            }
            return .result(outputs)
        case .musicError(let code, let message): return .musicError(code: code, message: message)
        case .sendError(let code, let message): return .sendError(code: code, message: message)
        }
    }

    /// `MusicScript.selectOutput`: finds the device by id in Music's list,
    /// then sets `current AirPlay devices` to that one device by its index.
    /// Two events, milliseconds apart, so the index is still Music's.
    private func selectOutput(_ music: Target, id: String) -> ScriptOutput {
        let timeout: TimeInterval = 5
        switch outputs(music, timeout: timeout) {
        case .result(let devices):
            guard let index = devices.firstIndex(where: { $0.id == id }) else { return .value(.text("NOT_FOUND")) }
            let device = Specifier.element(Code.airPlayDevice, index: Int32(index + 1), of: .application)
            let list = NSAppleEventDescriptor.list()
            list.insert(device.descriptor, at: 0)
            return music.set(.property(Code.currentAirPlayDevices), to: list)
        case .musicError(let code, let message), .sendError(let code, let message):
            return .failure(code: code, message: message)
        }
    }

    /// Fills fields 3–10 from a track's `properties` record as the script
    /// does. Returns false where the script's outer `try` would have stopped.
    static func fill(_ f: inout [String], from p: NSAppleEventDescriptor) -> Bool {
        func field(_ code: FourCharCode) -> String? { p.forKeyword(code).map(AppleScriptText.of) }
        guard let name = field(Code.name) else { return false }
        f[2] = name
        guard let artist = field(Code.artist) else { return false }
        f[3] = artist
        guard let album = field(Code.album) else { return false }
        f[4] = album
        if let albumArtist = field(Code.albumArtist) { f[5] = albumArtist }
        guard let duration = field(Code.duration) else { return false }
        f[6] = duration
        if let pid = field(Code.persistentID) { f[7] = pid }
        if let databaseID = field(Code.databaseID) { f[8] = databaseID }
        guard let cls = field(Code.class) else { return false }
        f[9] = cls
        return true
    }

    /// `MusicScript.artworkSource`, event for event. `current track` is read
    /// once and the specific track it names is used from then on, so a skip
    /// mid-way can't pair one track's id with another's art.
    private func artwork(_ music: Target) -> ScriptOutput {
        let timeout: TimeInterval = 5
        // `try: set t to current track / on error: return "NO_TRACK"`
        let track: NSAppleEventDescriptor
        switch music.get(.property(Code.currentTrack), timeout: timeout) {
        case .result(let value?) where value.descriptorType == typeObjectSpecifier: track = value
        case .result, .musicError: return .value(.text("NO_TRACK"))
        case .sendError(let code, let message): return .failure(code: code, message: message)
        }
        let t = Specifier.raw(track)

        // `try: set pid to (persistent ID of t)`
        var pid = ""
        switch music.get(.property(Code.persistentID, of: t), timeout: timeout) {
        case .result(let value): pid = AppleScriptText.of(value)
        case .musicError: break
        case .sendError(let code, let message): return .failure(code: code, message: message)
        }

        // `if (count of artworks of t) is 0 then return {pid}`, outside any try.
        switch music.count(Code.artwork, in: t, timeout: timeout) {
        case .result(let value) where value?.int32Value == 0: return .value(.list([.text(pid)]))
        case .result: break
        case .musicError(let code, let message), .sendError(let code, let message):
            return .failure(code: code, message: message)
        }

        // `set d to raw data of artwork 1 of t / return {pid, d}`
        switch music.get(.property(Code.rawData, of: .element(Code.artwork, index: 1, of: t)), timeout: timeout) {
        case .result(let data?):
            return .value(.list([.text(pid), .data(data.data, type: AppleScriptRunner.fourCharCode(data.descriptorType))]))
        case .result(nil):
            return .failure(code: -1708, message: "Music returned no artwork data.")
        case .musicError(let code, let message), .sendError(let code, let message):
            return .failure(code: code, message: message)
        }
    }

    // MARK: Sending

    /// The real send. `.canInteract` lets Music interact with the user if an
    /// event needs it. Whether the first run's Automation prompt appears as it
    /// does for NSAppleScript is untested (STATUS.md).
    static func sendLive(_ event: NSAppleEventDescriptor, timeout: TimeInterval) -> Reply {
        do {
            let reply = try event.sendEvent(options: [.waitForReply, .canInteract], timeout: timeout)
            // `sendEvent` doesn't throw for an error Music sends back.
            if let number = reply.paramDescriptor(forKeyword: keyErrorNumber), number.int32Value != 0 {
                let code = Int(number.int32Value)
                let text = reply.paramDescriptor(forKeyword: keyErrorString)?.stringValue
                return .musicError(code: code, message: text ?? Self.message(for: code))
            }
            return .result(reply.paramDescriptor(forKeyword: keyDirectObject))
        } catch {
            let code = (error as NSError).code
            return .sendError(code: code, message: Self.message(for: code))
        }
    }

    /// AppleScript's wording for the codes the controller tells apart.
    static func message(for code: Int) -> String {
        switch code {
        case -600: "Application isn’t running."
        case -609: "Connection is invalid."
        case -1712: "AppleEvent timed out."
        case -1728: "Can’t get the object."
        case -1743: "Not authorized to send Apple events to Music."
        case -1744: "Sending Apple events to Music needs your consent."
        default: "Apple Event error."
        }
    }

    /// Music, as one process.
    struct Target {
        let pid: pid_t
        let send: Send

        func get(_ specifier: Specifier, timeout: TimeInterval) -> Reply {
            let event = make(Code.coreSuite, Code.getData)
            event.setParam(specifier.descriptor, forKeyword: keyDirectObject)
            return send(event, timeout)
        }

        func count(_ elementClass: FourCharCode, in container: Specifier, timeout: TimeInterval) -> Reply {
            let event = make(Code.coreSuite, Code.countElements)
            event.setParam(container.descriptor, forKeyword: keyDirectObject)
            event.setParam(NSAppleEventDescriptor(typeCode: elementClass), forKeyword: Code.objectClass)
            return send(event, timeout)
        }

        func command(_ command: MusicCommand) -> ScriptOutput {
            switch send(make(Code.musicSuite, command.eventID), 3) {
            case .result: .value(.text("ok"))
            case .musicError(let code, let message), .sendError(let code, let message): .failure(code: code, message: message)
            }
        }

        /// `set <specifier> to <value>`: a `core/setd` event with the value as `data`.
        func set(_ specifier: Specifier, to value: NSAppleEventDescriptor, timeout: TimeInterval = 3) -> ScriptOutput {
            let event = make(Code.coreSuite, Code.setData)
            event.setParam(specifier.descriptor, forKeyword: keyDirectObject)
            event.setParam(value, forKeyword: Code.data)
            switch send(event, timeout) {
            case .result: return .value(.text("ok"))
            case .musicError(let code, let message), .sendError(let code, let message): return .failure(code: code, message: message)
            }
        }

        private func make(_ eventClass: FourCharCode, _ eventID: FourCharCode) -> NSAppleEventDescriptor {
            NSAppleEventDescriptor.appleEvent(withEventClass: eventClass, eventID: eventID,
                                              targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
                                              returnID: AEReturnID(kAutoGenerateReturnID),
                                              transactionID: AETransactionID(kAnyTransactionID))
        }
    }
}

/// An object specifier: what `of` builds in AppleScript.
indirect enum Specifier {
    case application
    case property(FourCharCode, of: Specifier = .application)
    case element(FourCharCode, index: Int32, of: Specifier)
    /// `every <class>` of the application.
    case every(FourCharCode)
    /// A specifier Music returned, such as the track `current track` names.
    case raw(NSAppleEventDescriptor)

    var descriptor: NSAppleEventDescriptor {
        switch self {
        case .application: return .null()
        case .raw(let descriptor): return descriptor
        case .every(let cls):
            // `every`: formAbsolutePosition with kAEAll, which is an absolute
            // ordinal ('abso'), not an enumeration. Music answers -10001 to the latter.
            return Self.make(want: cls, form: Code.formIndex, data: Self.ordinal(Code.all), from: .application)
        case .property(let code, let container):
            return Self.make(want: Code.propertyClass, form: Code.formProperty,
                             data: NSAppleEventDescriptor(typeCode: code), from: container)
        case .element(let cls, let index, let container):
            return Self.make(want: cls, form: Code.formIndex, data: NSAppleEventDescriptor(int32: index), from: container)
        }
    }

    /// A four-byte ordinal travels in host byte order, as `typeType` and
    /// `typeEnumerated` do; AppleScript's own `every` prints as `abso($206c6c61)`
    /// on this Mac, " lla" in memory. Big-endian bytes got -1728 from Music.
    static func ordinal(_ code: FourCharCode) -> NSAppleEventDescriptor {
        var native = code
        return NSAppleEventDescriptor(descriptorType: typeAbsoluteOrdinal, data: Data(bytes: &native, count: 4))!
    }

    private static func make(want: FourCharCode, form: FourCharCode, data: NSAppleEventDescriptor,
                             from container: Specifier) -> NSAppleEventDescriptor {
        let spec = NSAppleEventDescriptor.record().coerce(toDescriptorType: typeObjectSpecifier)!
        spec.setDescriptor(NSAppleEventDescriptor(typeCode: want), forKeyword: Code.desiredClass)
        spec.setDescriptor(NSAppleEventDescriptor(enumCode: form), forKeyword: Code.keyForm)
        spec.setDescriptor(data, forKeyword: Code.keyData)
        spec.setDescriptor(container.descriptor, forKeyword: Code.container)
        return spec
    }
}

/// Four-character codes, from `sdef /System/Applications/Music.app` (Music
/// 1.7, macOS 27.0.1) and the Apple Event Manager.
enum Code {
    static func fcc(_ text: StaticString) -> FourCharCode {
        precondition(text.utf8CodeUnitCount == 4)
        return text.withUTF8Buffer { $0.reduce(0) { $0 << 8 | FourCharCode($1) } }
    }

    // Events
    static let coreSuite = fcc("core")
    static let getData = fcc("getd")
    static let setData = fcc("setd")
    static let data = fcc("data")
    static let countElements = fcc("cnte")
    static let musicSuite = fcc("hook")
    static let objectClass = fcc("kocl")

    // Object specifiers
    static let desiredClass = fcc("want")
    static let keyForm = fcc("form")
    static let keyData = fcc("seld")
    static let container = fcc("from")
    static let propertyClass = fcc("prop")
    static let formProperty = fcc("prop")
    static let formIndex = fcc("indx")
    /// `every`: kAEAll, used with `formIndex`.
    static let all = fcc("all ")

    // Application properties
    static let playerState = fcc("pPlS")
    static let playerPosition = fcc("pPos")
    static let currentTrack = fcc("pTrk")
    static let properties = fcc("pALL")
    static let soundVolume = fcc("pVol")
    static let currentAirPlayDevices = fcc("pAPD")

    // AirPlay devices
    static let airPlayDevice = fcc("cAPD")
    static let kind = fcc("pKnd")
    static let selected = fcc("selc")
    static let available = fcc("pAva")
    static let networkAddress = fcc("pMAC")

    // Track and artwork
    static let name = fcc("pnam")
    static let artist = fcc("pArt")
    static let album = fcc("pAlb")
    static let albumArtist = fcc("pAlA")
    static let duration = fcc("pDur")
    static let persistentID = fcc("pPIS")
    static let databaseID = fcc("pDID")
    static let `class` = fcc("pcls")
    static let artwork = fcc("cArt")
    static let rawData = fcc("pRaw")
    static let missingValue = fcc("msng")
}

extension MusicCommand {
    /// The `hook` event ID, from Music's sdef.
    var eventID: FourCharCode {
        switch self {
        case .play: Code.fcc("Play")
        case .pause: Code.fcc("Paus")
        case .playPause: Code.fcc("PlPs")
        case .next: Code.fcc("Next")
        case .previous: Code.fcc("Prev")
        }
    }
}

/// What `as text` makes of a value in AppleScript, for the values these
/// scripts read. Music's enumerations and classes are named as its sdef names
/// them; an unknown code is written the way AppleScript writes it.
enum AppleScriptText {
    static let playerStates: [FourCharCode: String] = [
        Code.fcc("kPSS"): "stopped", Code.fcc("kPSP"): "playing", Code.fcc("kPSp"): "paused",
        Code.fcc("kPSF"): "fast forwarding", Code.fcc("kPSR"): "rewinding",
    ]
    /// `kind of AirPlay device as text`, from the `eAPD` enumeration.
    static let airPlayKinds: [FourCharCode: String] = [
        Code.fcc("kAPC"): "computer", Code.fcc("kAPX"): "AirPort Express", Code.fcc("kAPT"): "Apple TV",
        Code.fcc("kAPO"): "AirPlay device", Code.fcc("kAPB"): "Bluetooth device", Code.fcc("kAPH"): "HomePod",
        Code.fcc("kAPV"): "TV", Code.fcc("kAPU"): "unknown",
    ]
    static let classes: [FourCharCode: String] = [
        Code.fcc("cTrk"): "track", Code.fcc("cFlT"): "file track", Code.fcc("cURT"): "URL track",
        Code.fcc("cShT"): "shared track", Code.fcc("cCDT"): "audio CD track",
    ]

    static func of(_ descriptor: NSAppleEventDescriptor?) -> String {
        guard let descriptor else { return "missing value" }
        switch descriptor.descriptorType {
        case typeUnicodeText, typeUTF8Text, typeChar, typeUTF16ExternalRepresentation:
            return descriptor.stringValue ?? ""
        case typeSInt32, typeSInt16:
            return String(descriptor.int32Value)
        case typeSInt64, typeUInt32, typeUInt64:
            return descriptor.stringValue ?? String(descriptor.int32Value)
        case typeIEEE64BitFloatingPoint, typeIEEE32BitFloatingPoint:
            return real(descriptor.doubleValue)
        case typeEnumerated:
            let code = descriptor.enumCodeValue
            return playerStates[code] ?? airPlayKinds[code] ?? "«constant ****\(AppleScriptRunner.fourCharCode(code))»"
        case typeType:
            let code = descriptor.typeCodeValue
            if code == Code.missingValue { return "missing value" }
            return classes[code] ?? "«class \(AppleScriptRunner.fourCharCode(code))»"
        case typeTrue: return "true"
        case typeFalse: return "false"
        case typeBoolean: return descriptor.booleanValue ? "true" : "false"
        case typeNull: return "missing value"
        default:
            return descriptor.stringValue ?? ""
        }
    }

    /// AppleScript's `real as text`, measured with `osascript` on macOS 27.0.1:
    /// at most 12 decimals with trailing zeros dropped but one kept
    /// (`214.0`, `205.307006835938`), and `1.2345678e+4` from 10000 up and at
    /// 0.001 and below. Always a full stop: the parser accepts both.
    static func real(_ value: Double) -> String {
        guard value.isFinite else { return value.isNaN ? "nan" : (value < 0 ? "-inf" : "inf") }
        let magnitude = abs(value)
        guard value != 0, magnitude >= 10_000 || magnitude <= 0.001 else { return fixed(value) }
        var exponent = Int(floor(log10(magnitude)))
        var mantissa = value / pow(10, Double(exponent))
        if abs(Double(fixed(mantissa)) ?? 0) >= 10 {
            exponent += 1
            mantissa /= 10
        }
        return "\(fixed(mantissa))e\(exponent < 0 ? "-" : "+")\(abs(exponent))"
    }

    private static func fixed(_ value: Double) -> String {
        var text = String(format: "%.12f", locale: Locale(identifier: "en_US_POSIX"), value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text += "0" }
        return text == "-0.0" ? "0.0" : text
    }
}
