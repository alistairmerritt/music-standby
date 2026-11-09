// msbctl — drives CompanionCore against the real Music.app from a terminal.
// For verifying the Swift integration; the app itself is the menu-bar target.
//
//   msbctl snapshot                one read, plus the PlaybackMessage it makes
//   msbctl artwork [--out DIR]     artwork id (SHA-256 of Music's bytes) and the JPEG served
//   msbctl control VERB            play | pause | playpause | next | previous (changes playback)
//   msbctl watch [SECONDS]         the full companion against the mock relay. Reads
//                                  phone commands from stdin: play, pause, next, previous,
//                                  stale, dup, seek, drop
//
// None of these launch Music: every read is guarded by a process check first.

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
        let snapshot = controller.snapshot()
        print(describe(snapshot))
        print("read took \(Int(Date().timeIntervalSince(started) * 1000)) ms; scripts run: \(controller.scriptsRun), answered by process check: \(controller.skippedWhileClosed)")
        var publisher = PlaybackPublisher(revisions: RevisionCounter(lastPersisted: nil))
        if let message = publisher.ingest(snapshot, artworkID: nil) { print(json(.state(message))) }
        return 0
    }

case "artwork":
    run {
        let controller = MusicController()
        let started = Date()
        let result = controller.artwork()
        let ms = Int(Date().timeIntervalSince(started) * 1000)
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
        let before = controller.snapshot()
        print("before: \(before.state.rawValue) \(before.track?.title ?? "-") @ \(String(format: "%.1f", before.position))")
        let outcome = controller.perform(command)
        print("\(word): \(outcome)")
        try? await Task.sleep(for: .milliseconds(400))
        let after = controller.snapshot()
        print("after:  \(after.state.rawValue) \(after.track?.title ?? "-") @ \(String(format: "%.1f", after.position)) pid \(after.track?.persistentID ?? "-")")
        return outcome == .performed ? 0 : 1
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
        print("""
        \(stamp()) done.
          playerInfo notifications: \(companion.monitor.notificationsReceived)
          scripts run: \(companion.controller.scriptsRun), reads answered by process check: \(companion.controller.skippedWhileClosed)
          frames sent: \(sent.count) (\(sent.filter { if case .state = $0 { true } else { false } }.count) state)
        """)
        return 0
    }

default:
    print("""
    usage: msbctl snapshot
           msbctl artwork [--out DIR]
           msbctl control play|pause|playpause|next|previous
           msbctl watch [SECONDS]
    """)
    exit(arguments.isEmpty ? 0 : 2)
}
