// msbctl — drives CompanionCore against the real Music.app from a terminal.
// For verifying the Swift integration; the app itself is the menu-bar target.
//
//   msbctl snapshot                one read, plus the PlaybackMessage it makes
//   msbctl artwork [--out DIR]     artwork id (SHA-256 of Music's bytes) and the JPEG served
//   msbctl compare [ROUNDS]        snapshot and artwork through both runners, raw Apple
//                                  Events and AppleScript: same output, and how long each took
//   msbctl control VERB            play | pause | playpause | next | previous (changes playback)
//   msbctl watch [SECONDS]         the full companion against the mock relay. Reads
//                                  phone commands from stdin: play, pause, next, previous,
//                                  stale, dup, seek, drop; and `read`, which asks the
//                                  monitor for a read as a notification would
//
// None of these launch Music: every read is guarded by a process check first, and
// raw events are addressed to Music's process id. `compare` also runs the
// AppleScript reference, which addresses Music by name; it checks first.

import CompanionCore
import Foundation
import StandByProtocol

setvbuf(stdout, nil, _IOLBF, 0)
let arguments = Array(CommandLine.arguments.dropFirst())

func stamp(_ date: Date = Date()) -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: date)
}

func describe(_ s: MusicSnapshot) -> String {
    var lines = ["state:     \(s.state.rawValue)", "position:  \(String(format: "%.3f", s.position)) s"]
    if let t = s.track {
        lines += ["track:     \(t.title)", "artist:    \(t.artist)", "album:     \(t.album)",
                  "duration:  \(t.duration) s", "pid:       \(t.persistentID ?? "-") (db \(t.databaseID.map(String.init) ?? "-"))",
                  "class:     \(t.trackClass ?? "-")", "artworks:  \(t.artworkCount)", "trackID:   \(t.trackID)"]
    } else {
        lines.append("track:     (none)")
    }
    if let d = s.detail { lines.append("detail:    \(d)") }
    return lines.joined(separator: "\n")
}

func json(_ frame: MacFrame) -> String {
    (try? frame.encoded()).map { String(decoding: $0, as: UTF8.self) } ?? "<unencodable>"
}

func option(_ name: String) -> String? {
    guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
    return arguments[i + 1]
}

/// The longest the main thread went without running while `body` ran: how
/// much a read blocks the UI.
@MainActor
func mainThreadStall<T: Sendable>(during body: () async -> T) async -> (T, Double) {
    let probe = Task { @MainActor in
        var last = Date()
        var worst = 0.0
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(2))
            let now = Date()
            worst = max(worst, now.timeIntervalSince(last))
            last = now
        }
        return worst
    }
    await Task.yield()
    let value = await body()
    probe.cancel()
    return (value, await probe.value * 1000)
}

func ms(since start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }

func summary(_ output: ScriptOutput) -> String {
    func value(_ v: ScriptValue) -> String {
        switch v {
        case .text(let t): "\"\(t.replacingOccurrences(of: SnapshotParser.separator, with: "␟"))\""
        case .data(let d, let type): "<\(d.count) bytes '\(type)' sha256 \(ArtworkID.make(sourceBytes: d))>"
        case .list(let items): "[" + items.map(value).joined(separator: ", ") + "]"
        }
    }
    switch output {
    case .notRunning: return "notRunning"
    case .failure(let code, let message): return "failure \(code) \(message)"
    case .value(let v): return value(v)
    }
}

func run(_ body: @escaping @MainActor () async -> Int32) -> Never {
    Task { @MainActor in exit(await body()) }
    RunLoop.main.run()
    exit(0)
}

switch arguments.first {
case "snapshot":
    run {
        let controller = MusicController()
        let started = Date()
        let (snapshot, stall) = await mainThreadStall { await controller.snapshot() }
        print(describe(snapshot))
        print("read took \(ms(since: started)) ms, longest main-thread stall \(Int(stall)) ms; scripts run: \(await controller.scriptsRun), answered by process check: \(await controller.skippedWhileClosed)")
        var publisher = PlaybackPublisher(revisions: RevisionCounter(lastPersisted: nil))
        if let message = publisher.ingest(snapshot, artworkID: nil) { print(json(.state(message))) }
        return 0
    }

case "artwork":
    run {
        let controller = MusicController()
        let started = Date()
        let result = await controller.artwork()
        let ms = ms(since: started)
        guard case .image(let bytes, let pid, let type) = result else {
            print("no artwork: \(result) (\(ms) ms)")
            return 1
        }
        let id = ArtworkID.make(sourceBytes: bytes)
        print("source:    \(bytes.count) bytes, descriptor '\(type)', \(ArtworkProcessor.format(of: bytes)), track \(pid ?? "-"), \(ms) ms")
        print("artworkID: \(id)")
        let processed = ArtworkProcessor.process(bytes)
        if let d = processed?.descriptor {
            print("served:    \(d.contentType) \(d.width ?? 0)×\(d.height ?? 0), \(d.byteCount) bytes")
        } else {
            print("served:    ImageIO could not decode the source")
        }
        if let dir = option("--out") {
            let folder = URL(fileURLWithPath: dir, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let ext = ArtworkProcessor.format(of: bytes) == "jpeg" ? "jpg" : ArtworkProcessor.format(of: bytes)
            try? bytes.write(to: folder.appendingPathComponent("\(id).\(ext)"))
            if let processed { try? processed.image.write(to: folder.appendingPathComponent("\(id)-served.jpg")) }
            print("written to \(folder.path)")
        }
        return 0
    }

case "control":
    let verbs: [String: MusicCommand] = ["play": .play, "pause": .pause, "playpause": .playPause, "next": .next, "previous": .previous]
    guard let word = arguments.dropFirst().first, let command = verbs[word] else {
        print("usage: msbctl control play|pause|playpause|next|previous")
        exit(2)
    }
    run {
        let controller = MusicController()
        let before = await controller.snapshot()
        print("before: \(before.state.rawValue) \(before.track?.title ?? "-") @ \(String(format: "%.1f", before.position))")
        let outcome = await controller.perform(command)
        print("\(word): \(outcome)")
        try? await Task.sleep(for: .milliseconds(400))
        let after = await controller.snapshot()
        print("after:  \(after.state.rawValue) \(after.track?.title ?? "-") @ \(String(format: "%.1f", after.position)) pid \(after.track?.persistentID ?? "-")")
        return outcome == .performed ? 0 : 1
    }

case "compare":
    // Read-only. The AppleScript side runs on the main thread, as it must; the
    // raw side runs on a background thread, as the controller runs it.
    let rounds = Int(arguments.dropFirst().first ?? "") ?? 3
    run {
        let raw = RawEventRunner()
        let apple = AppleScriptRunner()
        var identical = true
        for script in [MusicScript.snapshot, .artwork] {
            var appleTimes: [Int] = [], rawTimes: [Int] = []
            for round in 1...rounds {
                // Checked before each AppleScript run: it addresses Music by name.
                guard MusicController.isMusicRunning() else {
                    print("Music is not running; nothing compared")
                    return 1
                }
                var started = Date()
                let a = apple.run(script)
                appleTimes.append(ms(since: started))
                started = Date()
                let r = await Task.detached { raw.run(script) }.value
                rawTimes.append(ms(since: started))
                if a == r {
                    if round == 1 { print("\(script): identical: \(summary(r).prefix(400))") }
                } else {
                    identical = false
                    print("\(script) round \(round): DIFFERENT")
                    print("  AppleScript: \(summary(a).prefix(600))")
                    print("  raw events:  \(summary(r).prefix(600))")
                }
            }
            print("  \(script) ms — AppleScript (main): \(appleTimes), raw events (background): \(rawTimes)")
        }
        print(identical ? "all identical" : "differences found (a playing track's position moves between the two reads)")
        return identical ? 0 : 1
    }

case "watch":
    let seconds = Double(arguments.dropFirst().first ?? "") ?? 60
    run {
        let defaults = UserDefaults(suiteName: "com.alistairmerritt.MusicStandBy.msbctl")!
        let store = CompanionStore(defaults: defaults)
        let mock = MockRelayTransport(log: { print("\(stamp()) \($0)") })
        let device = store.deviceIdentity(name: (Host.current().localizedName ?? "Mac") + " (msbctl)", appVersion: "msbctl")
        let companion = Companion(controller: MusicController(), transport: mock, store: store, device: device)
        companion.onEvent = { print("\(stamp($0.date)) • \($0.text)") }
        companion.start()
        print("\(stamp()) watching for \(Int(seconds)) s")

        Task.detached {
            while let line = readLine() {
                let word = line.trimmingCharacters(in: .whitespaces).lowercased()
                switch word {
                case "play", "pause", "next", "previous":
                    await mock.simulateCommand(CommandKind(rawValue: word)!)
                case "stale":
                    await mock.simulateCommand(.pause, issuedAt: Date().addingTimeInterval(-60))
                case "dup":
                    let id = UUID()
                    await mock.simulateCommand(.play, id: id)
                    await mock.simulateCommand(.play, id: id)
                case "seek":
                    await mock.simulateJSON(Data(#"{"type":"command","command":{"id":"\#(UUID().uuidString)","kind":"seek"}}"#.utf8))
                case "read":
                    await companion.refresh()
                case "drop":
                    await mock.simulateDrop(retryAt: Date().addingTimeInterval(1))
                    try? await Task.sleep(for: .seconds(1))
                    await mock.connect(hello: Hello(device: device))
                default:
                    print("unknown input: \(word)")
                }
            }
        }

        try? await Task.sleep(for: .seconds(seconds))
        await companion.stop()
        await companion.settle()
        let sent = await mock.sent
        let scripts = await companion.controller.scriptsRun
        let skipped = await companion.controller.skippedWhileClosed
        print("""
        \(stamp()) done.
          playerInfo notifications: \(companion.monitor.notificationsReceived)
          scripts run: \(scripts), reads answered by process check: \(skipped)
          frames sent: \(sent.count) (\(sent.filter { if case .state = $0 { true } else { false } }.count) state)
        """)
        return 0
    }

default:
    print("""
    usage: msbctl snapshot
           msbctl artwork [--out DIR]
           msbctl compare [ROUNDS]
           msbctl control play|pause|playpause|next|previous
           msbctl watch [SECONDS]
    """)
    exit(arguments.isEmpty ? 0 : 2)
}
