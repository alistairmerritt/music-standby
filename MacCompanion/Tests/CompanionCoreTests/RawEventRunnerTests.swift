import Foundation
import StandByProtocol
import Testing
@testable import CompanionCore

/// `RawEventRunner` against canned Apple Event replies. The live check, the
/// same output as `AppleScriptRunner` from the real Music, is `msbctl compare`.
@Suite struct RawEventRunnerTests {
    /// Records every event and answers from a table keyed by its object path,
    /// e.g. "pPlS of app" or "pRaw of cArt[1] of cURT[86657] of app".
    final class Events: @unchecked Sendable {
        struct Sent { var event: String; var path: String; var pid: Int32; var objectClass: String?; var data: NSAppleEventDescriptor? }
        private let lock = NSLock()
        private var _sent: [Sent] = []
        var replies: [String: RawEventRunner.Reply] = [:]

        var sent: [Sent] { lock.withLock { _sent } }
        var paths: [String] { sent.map(\.path) }

        func runner(pid: pid_t? = 4242, exists: Bool = true) -> RawEventRunner {
            RawEventRunner(processID: { pid }, processExists: { _ in exists },
                           send: { [unowned self] event, _ in self.answer(event) })
        }

        private func answer(_ event: NSAppleEventDescriptor) -> RawEventRunner.Reply {
            let name = code(event.eventClass) + "/" + code(event.eventID)
            let path = Self.path(event.paramDescriptor(forKeyword: keyDirectObject))
            // The address stays 'kpid', the PID's own bytes; int32Value won't coerce it.
            let address = event.attributeDescriptor(forKeyword: keyAddressAttr)
            let pid = address?.descriptorType == typeKernelProcessID
                ? address!.data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) } : -1
            let cls = event.paramDescriptor(forKeyword: Code.objectClass).map { code($0.typeCodeValue) }
            let data = event.paramDescriptor(forKeyword: Code.data)
            lock.withLock { _sent.append(Sent(event: name, path: path, pid: pid, objectClass: cls, data: data)) }
            let key = name == "core/getd" ? path : name == "core/cnte" ? "count \(cls ?? "?") of \(path)" : name == "core/setd" ? "set \(path)" : name
            return replies[key] ?? .musicError(code: -1708, message: "fake Music doesn’t understand \(key)")
        }

        static func path(_ d: NSAppleEventDescriptor?) -> String {
            guard let d else { return "-" }
            if d.descriptorType == typeNull { return "app" }
            guard d.descriptorType == typeObjectSpecifier,
                  let want = d.forKeyword(Code.desiredClass)?.typeCodeValue,
                  let seld = d.forKeyword(Code.keyData) else { return "?" }
            let from = path(d.forKeyword(Code.container))
            if want == Code.propertyClass { return "\(code(seld.typeCodeValue)) of \(from)" }
            if seld.descriptorType == typeAbsoluteOrdinal {
                let ordinal = seld.data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
                return "\(code(want))[\(code(ordinal))] of \(from)"
            }
            return "\(code(want))[\(seld.int32Value)] of \(from)"
        }
    }

    static func code(_ c: FourCharCode) -> String { AppleScriptRunner.fourCharCode(c) }
    private func code(_ c: FourCharCode) -> String { Self.code(c) }

    static func text(_ s: String) -> NSAppleEventDescriptor { NSAppleEventDescriptor(string: s) }
    static func type(_ s: StaticString) -> NSAppleEventDescriptor { NSAppleEventDescriptor(typeCode: Code.fcc(s)) }
    static func enumerated(_ s: StaticString) -> NSAppleEventDescriptor { NSAppleEventDescriptor(enumCode: Code.fcc(s)) }

    /// What Music returns for `current track`: a reference to one track by id.
    static func trackReference() -> NSAppleEventDescriptor {
        let spec = NSAppleEventDescriptor.record().coerce(toDescriptorType: typeObjectSpecifier)!
        spec.setDescriptor(type("cURT"), forKeyword: Code.desiredClass)
        spec.setDescriptor(enumerated("ID  "), forKeyword: Code.keyForm)
        spec.setDescriptor(NSAppleEventDescriptor(int32: 86657), forKeyword: Code.keyData)
        spec.setDescriptor(.null(), forKeyword: Code.container)
        return spec
    }

    static func trackProperties(without missing: Set<String> = []) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        let fields: [(StaticString, NSAppleEventDescriptor)] = [
            ("pcls", type("cURT")), ("pnam", text("Losing My Edge")), ("pArt", text("LCD Soundsystem")),
            ("pAlb", text("LCD Soundsystem")), ("pAlA", text("")), ("pDur", NSAppleEventDescriptor(double: 473.11400634765625)),
            ("pPIS", text("542CEB17C137B39E")), ("pDID", NSAppleEventDescriptor(int32: 86657)),
            ("pGen", text("Dance")), ("pTrN", NSAppleEventDescriptor(int32: 1)),
        ]
        for (key, value) in fields where !missing.contains("\(key)") {
            record.setDescriptor(value, forKeyword: Code.fcc(key))
        }
        return record
    }

    /// `properties of every AirPlay device`: the Mac, a HomePod and an Apple TV.
    static func airPlayDevices() -> NSAppleEventDescriptor {
        let list = NSAppleEventDescriptor.list()
        let devices: [(String, StaticString, Bool, Bool, String?)] = [
            ("Alistair's MacBook Pro", "kAPC", true, true, nil),
            ("Living Room", "kAPH", false, true, "e4:6e:91:c0:a6:d2"),
            ("Bedroom Apple TV", "kAPT", false, false, "12:89:91:41:fe:be"),
        ]
        for (index, (name, kind, selected, available, address)) in devices.enumerated() {
            let record = NSAppleEventDescriptor.record()
            record.setDescriptor(type("cAPD"), forKeyword: Code.fcc("pcls"))
            record.setDescriptor(text(name), forKeyword: Code.name)
            record.setDescriptor(enumerated(kind), forKeyword: Code.kind)
            record.setDescriptor(NSAppleEventDescriptor(boolean: selected), forKeyword: Code.selected)
            record.setDescriptor(NSAppleEventDescriptor(boolean: available), forKeyword: Code.available)
            record.setDescriptor(address.map(text) ?? type("msng"), forKeyword: Code.networkAddress)
            list.insert(record, at: index + 1)
        }
        return list
    }

    static let deviceFields = ["Alistair's MacBook Pro", "computer", "true", "true", "missing value"].joined(separator: MusicScript.outputFieldSeparator)
        + MusicScript.outputSeparator
        + ["Living Room", "HomePod", "false", "true", "e4:6e:91:c0:a6:d2"].joined(separator: MusicScript.outputFieldSeparator)
        + MusicScript.outputSeparator
        + ["Bedroom Apple TV", "Apple TV", "false", "false", "12:89:91:41:fe:be"].joined(separator: MusicScript.outputFieldSeparator)
        + MusicScript.outputSeparator

    private func playing(_ events: Events) {
        events.replies = [
            "pPlS of app": .result(Self.enumerated("kPSP")),
            "pPos of app": .result(NSAppleEventDescriptor(double: 251.04)),
            "pALL of pTrk of app": .result(Self.trackProperties()),
            "count cArt of pTrk of app": .result(NSAppleEventDescriptor(int32: 1)),
            "pVol of app": .result(NSAppleEventDescriptor(int32: 65)),
            "pALL of cAPD[all ] of app": .result(Self.airPlayDevices()),
        ]
    }

    private let sep = SnapshotParser.separator
    private let tail = ["pVol of app", "pALL of cAPD[all ] of app"]

    // MARK: Snapshot

    @Test func snapshotMatchesTheScriptsText() {
        let events = Events()
        playing(events)
        let output = events.runner().run(.snapshot)
        let expected = ["playing", "251.04", "Losing My Edge", "LCD Soundsystem", "LCD Soundsystem", "",
                        "473.114006347656", "542CEB17C137B39E", "86657", "URL track", "1", "65", Self.deviceFields].joined(separator: sep)
        #expect(output == .value(.text(expected)))
        #expect(events.paths == ["pPlS of app", "pPos of app", "pALL of pTrk of app", "pTrk of app"] + tail)
        #expect(events.sent.map(\.event) == ["core/getd", "core/getd", "core/getd", "core/cnte", "core/getd", "core/getd"])
        #expect(events.sent.allSatisfy { $0.pid == 4242 })
        #expect(events.sent[3].objectClass == "cArt")
        let parsed = SnapshotParser.parse(expected, capturedAt: Date())
        #expect(parsed.track?.duration == 473.114)
        #expect(parsed.track?.trackClass == "URL track")
        #expect(parsed.volume == 65)
        #expect(parsed.outputs == [
            AudioOutput(id: "name:Alistair's MacBook Pro", name: "Alistair's MacBook Pro", kind: .computer, isSelected: true),
            AudioOutput(id: "e4:6e:91:c0:a6:d2", name: "Living Room", kind: .homePod, isSelected: false),
            AudioOutput(id: "12:89:91:41:fe:be", name: "Bedroom Apple TV", kind: .appleTV, isSelected: false, isAvailable: false),
        ])
    }

    @Test func anOlderSnapshotWithoutVolumeOrOutputsStillParses() {
        let raw = ["paused", "1", "T", "A", "B", "", "100", "", "0", "track", "0"].joined(separator: sep)
        let parsed = SnapshotParser.parse(raw, capturedAt: Date())
        #expect(parsed.track?.title == "T" && parsed.volume == nil && parsed.outputs == nil)
    }

    @Test func nothingLoadedReadsAsStoppedWithNoTrack() {
        let events = Events()
        events.replies = [
            "pPlS of app": .result(Self.enumerated("kPSS")),
            "pPos of app": .result(Self.type("msng")),
            "pALL of pTrk of app": .musicError(code: -1728, message: "Can’t get current track."),
        ]
        let output = events.runner().run(.snapshot)
        #expect(output == .value(.text(["stopped", "missing value", "", "", "", "", "0", "", "0", "", "0", "", ""].joined(separator: sep))))
        // The script's `try` ends at the failed `properties`: no count is sent.
        // Volume and devices are read anyway, in their own `try`s.
        #expect(events.paths.count == 5)
        let parsed = SnapshotParser.parse(["stopped", "missing value"].joined(separator: sep), capturedAt: Date())
        #expect(parsed.state == .stopped && parsed.position == 0 && parsed.track == nil)
    }

    @Test func aFieldTheScriptReadsOutsideItsTryEndsTheBlock() {
        let events = Events()
        playing(events)
        events.replies["pALL of pTrk of app"] = .result(Self.trackProperties(without: ["pAlA", "pcls"]))
        guard case .value(.text(let raw)) = events.runner().run(.snapshot) else { Issue.record("no text"); return }
        let f = raw.components(separatedBy: sep)
        #expect(f[5] == "")            // album artist: inside its own try
        #expect(f[7] == "542CEB17C137B39E")
        #expect(f[9] == "" && f[10] == "0")   // class is not: the count is never sent
        #expect(events.paths.count == 5)
    }

    @Test func aMusicErrorOnPlayerStateFailsTheRead() {
        let events = Events()
        events.replies["pPlS of app"] = .musicError(code: -10000, message: "handler failed")
        #expect(events.runner().run(.snapshot) == .failure(code: -10000, message: "handler failed"))
    }

    /// The script's `try` around player position would have hidden these.
    @Test(arguments: [-600, -609, -1712, -1743])
    func sendErrorsAlwaysFailTheRead(code: Int) {
        let events = Events()
        playing(events)
        events.replies["pPos of app"] = .sendError(code: code, message: RawEventRunner.message(for: code))
        #expect(events.runner().run(.snapshot) == .failure(code: code, message: RawEventRunner.message(for: code)))
        #expect(events.paths.count == 2)
    }

    /// What quitting Music looked like: -609 for the event in flight, then -600.
    @Test(arguments: [-600, -609])
    func aProcessThatQuitIsNotRunning(code: Int) {
        let events = Events()
        playing(events)
        events.replies["pPos of app"] = .sendError(code: code, message: RawEventRunner.message(for: code))
        #expect(events.runner(exists: false).run(.snapshot) == .notRunning)
        events.replies["hook/Paus"] = .sendError(code: code, message: RawEventRunner.message(for: code))
        #expect(events.runner(exists: false).run(.command(.pause)) == .notRunning)
        // Still there: -609 alone is an error, as before.
        #expect(events.runner(exists: true).run(.command(.pause)) == .failure(code: code, message: RawEventRunner.message(for: code)))
    }

    @Test func aRefusalIsNeverNotRunning() {
        let events = Events()
        events.replies["pPlS of app"] = .sendError(code: -1743, message: RawEventRunner.message(for: -1743))
        #expect(events.runner(exists: false).run(.snapshot) == .failure(code: -1743, message: "Not authorized to send Apple events to Music."))
    }

    @Test func processExistsIsAProcessCheck() {
        #expect(RawEventRunner.processExists(getpid()))
        #expect(!RawEventRunner.processExists(pid_t.max))
    }

    @Test func noProcessMeansNoEvents() {
        let events = Events()
        playing(events)
        #expect(events.runner(pid: nil).run(.snapshot) == .notRunning)
        #expect(events.runner(pid: nil).run(.command(.play)) == .notRunning)
        #expect(events.sent.isEmpty)
    }

    // MARK: Artwork

    @Test func artworkIsReadFromTheTrackCurrentTrackNamed() {
        let events = Events()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        let track = "cURT[86657] of app"
        events.replies = [
            "pTrk of app": .result(Self.trackReference()),
            "pPIS of \(track)": .result(Self.text("542CEB17C137B39E")),
            "count cArt of \(track)": .result(NSAppleEventDescriptor(int32: 1)),
            "pRaw of cArt[1] of \(track)": .result(NSAppleEventDescriptor(descriptorType: Code.fcc("tdta"), data: png)),
        ]
        #expect(events.runner().run(.artwork) == .value(.list([.text("542CEB17C137B39E"), .data(png, type: "tdta")])))
        #expect(events.paths == ["pTrk of app", "pPIS of \(track)", track, "pRaw of cArt[1] of \(track)"])
    }

    @Test func artworkWithoutArtOrTrack() {
        let events = Events()
        let track = "cURT[86657] of app"
        events.replies = [
            "pTrk of app": .result(Self.trackReference()),
            "pPIS of \(track)": .musicError(code: -1728, message: "no id"),
            "count cArt of \(track)": .result(NSAppleEventDescriptor(int32: 0)),
        ]
        #expect(events.runner().run(.artwork) == .value(.list([.text("")])))
        events.replies["pTrk of app"] = .musicError(code: -1728, message: "Can’t get current track.")
        #expect(events.runner().run(.artwork) == .value(.text("NO_TRACK")))
        events.replies["pTrk of app"] = .sendError(code: -609, message: "Connection is invalid.")
        #expect(events.runner().run(.artwork) == .failure(code: -609, message: "Connection is invalid."))
    }

    // MARK: Commands

    @Test func commandsAreMusicsOwnEvents() {
        let events = Events()
        for (command, id) in [(MusicCommand.play, "Play"), (.pause, "Paus"), (.playPause, "PlPs"), (.next, "Next"), (.previous, "Prev")] {
            events.replies["hook/\(id)"] = .result(nil)
            #expect(events.runner().run(.command(command)) == .value(.text("ok")))
        }
        #expect(events.sent.map(\.event) == ["hook/Play", "hook/Paus", "hook/PlPs", "hook/Next", "hook/Prev"])
        events.replies["hook/Play"] = .sendError(code: -1743, message: RawEventRunner.message(for: -1743))
        #expect(events.runner().run(.command(.play)) == .failure(code: -1743, message: "Not authorized to send Apple events to Music."))
    }

    @Test func seekAndVolumeAreSetEvents() {
        let events = Events()
        events.replies["set pPos of app"] = .result(nil)
        events.replies["set pVol of app"] = .result(nil)
        #expect(events.runner().run(.seek(120.5)) == .value(.text("ok")))
        #expect(events.runner().run(.setVolume(40)) == .value(.text("ok")))
        #expect(events.sent.map(\.event) == ["core/setd", "core/setd"])
        #expect(events.paths == ["pPos of app", "pVol of app"])
        #expect(events.sent[0].data?.doubleValue == 120.5)
        #expect(events.sent[1].data?.int32Value == 40)
        events.replies["set pPos of app"] = .musicError(code: -10006, message: "Can’t set player position.")
        #expect(events.runner().run(.seek(1)) == .failure(code: -10006, message: "Can’t set player position."))
    }

    @Test func selectOutputFindsTheDeviceThenSetsTheCurrentDevices() {
        let events = Events()
        events.replies["pALL of cAPD[all ] of app"] = .result(Self.airPlayDevices())
        events.replies["set pAPD of app"] = .result(nil)
        #expect(events.runner().run(.selectOutput("e4:6e:91:c0:a6:d2")) == .value(.text("ok")))
        #expect(events.paths == ["pALL of cAPD[all ] of app", "pAPD of app"])
        let list = events.sent[1].data
        #expect(list?.numberOfItems == 1)
        #expect(Events.path(list?.atIndex(1)) == "cAPD[2] of app", "the HomePod is second in Music's list")
        #expect(events.runner().run(.selectOutput("name:Alistair's MacBook Pro")) == .value(.text("ok")))
        #expect(Events.path(events.sent[3].data?.atIndex(1)) == "cAPD[1] of app")
    }

    @Test func anUnknownOutputIsNotFoundAndNothingIsSet() {
        let events = Events()
        events.replies["pALL of cAPD[all ] of app"] = .result(Self.airPlayDevices())
        #expect(events.runner().run(.selectOutput("00:00:00:00:00:00")) == .value(.text("NOT_FOUND")))
        #expect(events.sent.map(\.event) == ["core/getd"])
    }

    // MARK: AppleScript's text

    /// Every pair measured with `osascript -e '(x as real) as text'` on macOS 27.0.1.
    @Test(arguments: [
        (473.114, "473.114"), (214.0, "214.0"), (205.30700683593751, "205.307006835938"), (251.04, "251.04"),
        (0.5, "0.5"), (0.0, "0.0"), (3.0, "3.0"), (-5.5, "-5.5"), (1.23456789012345678, "1.234567890123"),
        (123.4567890123456, "123.456789012346"), (9999.5, "9999.5"), (9999.999999999999, "9999.999999999998"),
        (10000.0, "1.0e+4"), (12345.678, "1.2345678e+4"), (12345.678901234567, "1.234567890123e+4"),
        (99999.99999999999, "1.0e+5"), (99999999.0, "9.9999999e+7"), (1.0e15, "1.0e+15"), (1.0e20, "1.0e+20"),
        (0.01, "0.01"), (0.009999999999999, "0.01"), (0.0099, "0.0099"), (0.005, "0.005"), (0.0011, "0.0011"),
        (0.012345678901234, "0.012345678901"), (0.001, "1.0e-3"), (0.00099, "9.9e-4"), (0.0002, "2.0e-4"),
        (0.0001, "1.0e-4"), (1.234567e-7, "1.234567e-7"), (1.0e-12, "1.0e-12"),
    ])
    func realsAreWrittenAsAppleScriptWritesThem(value: Double, text: String) {
        #expect(AppleScriptText.real(value) == text)
    }

    @Test func otherValuesAsText() {
        #expect(AppleScriptText.of(NSAppleEventDescriptor(int32: 86657)) == "86657")
        #expect(AppleScriptText.of(Self.type("msng")) == "missing value")
        #expect(AppleScriptText.of(nil) == "missing value")
        #expect(AppleScriptText.of(Self.enumerated("kPSp")) == "paused")
        #expect(AppleScriptText.of(Self.enumerated("kPSF")) == "fast forwarding")
        #expect(AppleScriptText.of(Self.enumerated("kZZZ")) == "«constant ****kZZZ»")
        #expect(AppleScriptText.of(Self.type("cFlT")) == "file track")
        #expect(AppleScriptText.of(Self.type("cZZZ")) == "«class cZZZ»")
    }
}

@Suite struct MusicProcessTests {
    /// The LaunchServices lookup flapped empty; a known, live PID must not.
    @Test func aKnownProcessSurvivesAnEmptyLookUp() {
        let answers = Answers([getpid(), nil, nil])
        let process = MusicProcess(lookUp: { answers.next() })
        #expect(process.pid() == getpid())
        #expect(process.pid() == getpid())
        #expect(process.pid() == getpid())
        #expect(answers.calls == 1)
    }

    @Test func aGoneProcessIsLookedUpAgain() {
        let answers = Answers([pid_t.max, nil, getpid()])
        let process = MusicProcess(lookUp: { answers.next() })
        #expect(process.pid() == nil)     // pid_t.max has no process, so no path
        #expect(process.pid() == nil)
        #expect(process.pid() == getpid())
        #expect(answers.calls == 3)
    }

    @Test func ageComesFromTheKernel() throws {
        let age = try #require(MusicProcess.age(of: getpid()))
        #expect(age >= 0 && age < 3600)
        #expect(MusicProcess.age(of: pid_t.max) == nil)
    }

    final class Answers: @unchecked Sendable {
        private let lock = NSLock()
        private var queue: [pid_t?]
        private(set) var calls = 0
        init(_ answers: [pid_t?]) { queue = answers }
        func next() -> pid_t? {
            lock.withLock {
                calls += 1
                return queue.isEmpty ? nil : queue.removeFirst()
            }
        }
    }
}
