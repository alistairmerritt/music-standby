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
//   msbctl watch … --relay URL     the same against a real relay over its WebSocket.
//                                  --credentials FILE (default in $TMPDIR) keeps the Mac's
//                                  token out of the Keychain; --pair prints a pairing code;
//                                  stdin also takes code, approve, deny and unpair;
//                                  --auto-approve allows every pairing (scripted tests only)
//   msbctl watch … --no-catalog    Music's own artwork only, no catalogue lookup
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
    lines.append("volume:    \(s.volume.map { "\($0) %" } ?? "(not read)")")
    if let outputs = s.outputs {
        lines.append("outputs:   \(outputs.count)")
        for o in outputs {
            lines.append("  \(o.isSelected ? "●" : "○") \(o.name) — \(o.kind.rawValue)\(o.isAvailable ? "" : ", unavailable")  [\(o.id)]")
        }
    }
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
    // seek <seconds>, volume <0-100> and output <id|name> were added on 11 November 2026.
    let verbs: [String: MusicCommand] = ["play": .play, "pause": .pause, "playpause": .playPause, "next": .next, "previous": .previous]
    let word = arguments.dropFirst().first ?? ""
    let value = arguments.dropFirst(2).joined(separator: " ")
    let usage = "usage: msbctl control play|pause|playpause|next|previous | seek <seconds> | volume <0-100> | output <id or name>"
    guard verbs[word] != nil || (["seek", "volume", "output"].contains(word) && !value.isEmpty) else {
        print(usage)
        exit(2)
    }
    run {
        let controller = MusicController()
        let before = await controller.snapshot()
        func line(_ s: MusicSnapshot) -> String {
            let outputs = s.outputs?.filter(\.isSelected).map(\.name).joined(separator: ", ") ?? "?"
            return "\(s.state.rawValue) \(s.track?.title ?? "-") @ \(String(format: "%.1f", s.position)) vol \(s.volume.map(String.init) ?? "?") → \(outputs)"
        }
        print("before: \(line(before))")
        let outcome: MusicController.CommandOutcome
        switch word {
        case "seek":
            guard let seconds = Double(value) else { print(usage); return 2 }
            outcome = await controller.seek(to: seconds)
        case "volume":
            guard let level = Int(value) else { print(usage); return 2 }
            outcome = await controller.setVolume(level)
        case "output":
            // An id as the wire has it, or a device name from the snapshot.
            let id = before.outputs?.first { $0.id == value || $0.name == value }?.id ?? value
            outcome = await controller.selectOutput(id)
        default:
            outcome = await controller.perform(verbs[word]!)
        }
        print("\(word)\(value.isEmpty ? "" : " \(value)"): \(outcome)")
        try? await Task.sleep(for: .milliseconds(word == "output" ? 1500 : 400))
        let after = await controller.snapshot()
        print("after:  \(line(after)) pid \(after.track?.persistentID ?? "-")")
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
    let seconds = arguments.dropFirst().compactMap(Double.init).first ?? 60
    let relayURL = option("--relay").flatMap(URL.init(string:))
    let credentialsPath = option("--credentials") ?? NSTemporaryDirectory() + "msbctl-relay-credentials.json"
    run {
        let defaults = UserDefaults(suiteName: "com.alistairmerritt.MusicStandBy.msbctl")!
        let store = CompanionStore(defaults: defaults)
        let device = store.deviceIdentity(name: (Host.current().localizedName ?? "Mac") + " (msbctl)", appVersion: "msbctl")

        // Mock relay by default; the real one with --relay.
        let mock = MockRelayTransport(log: { print("\(stamp()) \($0)") })
        var account: RelayAccount?
        let transport: any CompanionTransport
        if let relayURL {
            let relayAccount = RelayAccount(baseURL: relayURL, store: FileCredentialStore(url: URL(fileURLWithPath: credentialsPath)))
            await relayAccount.register(device: device)
            guard let credentials = relayAccount.credentials else {
                print("could not register with \(relayURL): \(relayAccount.lastError ?? "unknown error")")
                return 1
            }
            print("\(stamp()) relay \(relayURL.absoluteString), pairing \(credentials.pairingID.prefix(8))…, credentials in \(credentialsPath)")
            account = relayAccount
            transport = RelayTransport(client: relayAccount.client, token: relayAccount.token)
        } else {
            transport = mock
        }

        let lookup: (any CatalogArtworkLookup)? = arguments.contains("--no-catalog") ? nil : ITunesCatalogArtwork()
        let companion = Companion(controller: MusicController(), transport: transport, store: store, device: device, artworkLookup: lookup)
        companion.onEvent = { print("\(stamp($0.date)) • \($0.text)") }
        companion.autoApprovePairing = arguments.contains("--auto-approve")
        if let account {
            let transport = companion.transport
            companion.onCredentialsRejected = {
                Task { @MainActor in
                    await account.reregister(device: device)
                    print("\(stamp()) re-registered as pairing \(account.credentials?.pairingID.prefix(8) ?? "?")…")
                    await transport.connect(hello: Hello(device: device))
                }
            }
        }
        companion.start()
        print("\(stamp()) watching for \(Int(seconds)) s")

        if let account, arguments.contains("--pair") {
            await account.requestPairingCode()
            if let code = account.pairingCode {
                print("PAIRING CODE \(code.code) (expires \(StandByWire.formatDate(code.expiresAt)))")
            } else {
                print("no pairing code: \(account.lastError ?? "unknown error")")
            }
        }

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
                case "shuffle":   // a kind this build doesn't know
                    await mock.simulateJSON(Data(#"{"type":"command","command":{"id":"\#(UUID().uuidString)","kind":"shuffle"}}"#.utf8))
                case let w where w.hasPrefix("seek "):
                    if let seconds = Double(w.dropFirst(5)) { await mock.simulate(.seek(to: seconds)) }
                case let w where w.hasPrefix("volume "):
                    if let level = Double(w.dropFirst(7)) { await mock.simulate(.setVolume(level / 100)) }
                case let w where w.hasPrefix("output "):
                    await mock.simulate(.selectOutput(String(line.trimmingCharacters(in: .whitespaces).dropFirst(7))))
                case "read":
                    await companion.refresh()
                case "drop":
                    await mock.simulateDrop(retryAt: Date().addingTimeInterval(1))
                    try? await Task.sleep(for: .seconds(1))
                    await mock.connect(hello: Hello(device: device))
                case "code":
                    await account?.requestPairingCode()
                    if let code = await account?.pairingCode { print("PAIRING CODE \(code.code)") }
                case "approve", "deny":
                    if let request = await companion.pairRequests.first {
                        await companion.decidePairing(request.claimID, approved: word == "approve")
                    } else {
                        print("no pair request waiting")
                    }
                case "unpair":
                    await account?.unpair()
                    print("unpaired")
                default:
                    print("unknown input: \(word)")
                }
            }
        }

        try? await Task.sleep(for: .seconds(seconds))
        await companion.stop()
        await companion.settle()
        let scripts = await companion.controller.scriptsRun
        let skipped = await companion.controller.skippedWhileClosed
        let sent = await mock.sent
        print("""
        \(stamp()) done.
          playerInfo notifications: \(companion.monitor.notificationsReceived)
          scripts run: \(scripts), reads answered by process check: \(skipped)
          \(relayURL == nil ? "frames sent to the mock relay: \(sent.count)" : "connection: \(companion.connection.phase.rawValue)")
        """)
        return 0
    }

case "remote":
    // Read-only: the current song's catalogue ID and Up Next over Music's
    // remote protocol, with a pairing made elsewhere (the app, or a probe).
    run {
        let options = Array(arguments.dropFirst())
        if options.first == "pair", options.count == 2 {
            // Pairs a test remote and writes "GUID SERVICE-NAME" to the file
            // (owner-only), never to the screen: the GUID lets Music be read.
            let pairer = MusicRemotePairer(name: "Second Chair test")
            print("In Music, click “\(pairer.name)” under Devices in the sidebar and enter \(pairer.code). Waiting…")
            do {
                let pairing = try await pairer.pair()
                FileManager.default.createFile(atPath: options[1], contents: Data("\(pairing.guid) \(pairing.serviceName)".utf8),
                                               attributes: [.posixPermissions: 0o600])
                print("paired with Music's \(pairing.serviceName); saved to \(options[1])")
                return 0
            } catch {
                print("pairing failed: \(error)")
                return 1
            }
        }
        guard options.count >= 2 else {
            print("usage: msbctl remote GUID SERVICE-NAME   (from a pairing: 16 hex digits, and Music's _touch-able name)")
            return 2
        }
        let client = MusicRemoteClient(pairing: MusicRemotePairing(guid: options[0], serviceName: options[1]))
        let reader = options.contains("--no-catalog") ? client as any MusicRemoteReading
            : CatalogFillingRemote(remote: client, lookup: ITunesCatalogIDs())
        let snapshot = await MusicController().snapshot()
        let started = Date()
        let queue = await reader.queue(current: snapshot.track)
        print("now: \(snapshot.track.map { "\($0.title) — \($0.artist), persistent ID \($0.persistentID ?? "-")" } ?? "nothing")")
        print("remote: \(await client.status) in \(ms(since: started)) ms")
        guard let queue else { return 1 }
        print("catalogue ID: \(queue.catalogID ?? "-")")
        print("Up Next: \(queue.upNext.count)")
        print("  with a catalogue ID: \(queue.upNext.filter { $0.catalogID != nil }.count)")
        for (index, entry) in queue.upNext.prefix(5).enumerated() {
            print("  \(index + 1). \(entry.title) — \(entry.artist) (\(Int(entry.duration)) s) catalogue \(entry.catalogID ?? "-")")
        }
        let again = Date()
        _ = await reader.queue(current: snapshot.track)
        print("second read (library cached): \(ms(since: again)) ms")
        return 0
    }

default:
    print("""
    usage: msbctl snapshot
           msbctl artwork [--out DIR]
           msbctl compare [ROUNDS]
           msbctl control play|pause|playpause|next|previous
           msbctl remote GUID SERVICE-NAME [--no-catalog] | pair FILE
           msbctl watch [SECONDS] [--no-catalog] [--relay URL [--credentials FILE] [--pair] [--auto-approve]]
    """)
    exit(arguments.isEmpty ? 0 : 2)
}
