import AppKit
import CompanionCore
import StandByProtocol
import SwiftUI

struct MenuContent: View {
    let companion: Companion
    let relay: RelayAccount?
    let launchAtLogin: LaunchAtLogin

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NowPlayingSection(companion: companion)
            Divider()
            ConnectionSection(companion: companion, relay: relay)
            Divider()
            LaunchAtLoginRow(launchAtLogin: launchAtLogin)
            if let mock = companion.transport as? MockRelayTransport {
                MockRelaySection(companion: companion, mock: mock)
            }
            Divider()
            HStack {
                Spacer()
                Button("Quit Music StandBy") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}

// MARK: - Now playing

private struct NowPlayingSection: View {
    let companion: Companion

    var body: some View {
        switch companion.snapshot?.state {
        case nil:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking Music…").foregroundStyle(.secondary)
            }
        case .notRunning?:
            Notice(symbol: "music.note", title: "Music isn’t running",
                   detail: "Music StandBy never opens Music by itself.",
                   action: ("Open Music", openMusic))
        case .automationDenied?:
            Notice(symbol: "exclamationmark.triangle", title: "Music StandBy can’t read Music",
                   detail: "Allow it in System Settings › Privacy & Security › Automation.",
                   action: ("Open Privacy Settings", openAutomationSettings))
        default:
            if let snapshot = companion.snapshot, let track = snapshot.track {
                TrackRow(track: track, state: snapshot.state, artwork: companion.artwork?.image)
                if let message = companion.message, let duration = message.track?.duration, duration > 0 {
                    Progress(message: message, duration: duration)
                }
            } else {
                Notice(symbol: "music.note", title: companion.snapshot?.state == .error ? "Can’t read Music right now" : "Nothing playing",
                       detail: companion.snapshot?.detail, action: nil)
            }
            TransportControls(companion: companion)
        }
    }

    private func openMusic() {
        // Only ever on an explicit click.
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Music.app"), configuration: .init())
    }

    private func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct TrackRow: View {
    let track: MusicTrack
    let state: PlaybackState
    let artwork: Data?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if let artwork, let image = NSImage(data: artwork) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.quaternary)
                        .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).font(.headline).lineLimit(2)
                Text(track.artist).foregroundStyle(.secondary).lineLimit(1)
                Text(track.album).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                Text(stateText).font(.caption).foregroundStyle(.tertiary).padding(.top, 2)
            }
        }
    }

    private var stateText: String {
        switch state {
        case .playing: "Playing"
        case .paused: "Paused"
        case .error: "Can’t read Music right now"
        default: "Stopped"
        }
    }
}

/// Extrapolated from the last published message, exactly as the phone will.
private struct Progress: View {
    let message: PlaybackMessage
    let duration: TimeInterval

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = message.elapsed(at: context.date)
            VStack(spacing: 2) {
                ProgressView(value: min(elapsed, duration), total: duration)
                HStack {
                    Text(Self.format(elapsed))
                    Spacer()
                    Text("-" + Self.format(max(0, duration - elapsed)))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct TransportControls: View {
    let companion: Companion

    var body: some View {
        let state = companion.snapshot?.state
        let enabled = companion.snapshot?.track != nil && (state == .playing || state == .paused)
        HStack(spacing: 32) {
            Button { companion.perform(.previous) } label: { Image(systemName: "backward.fill") }
                .help("Previous").accessibilityLabel("Previous")
            Button { companion.perform(.playPause) } label: {
                Image(systemName: state == .playing ? "pause.fill" : "play.fill")
            }
            .help(state == .playing ? "Pause" : "Play")
            .accessibilityLabel(state == .playing ? "Pause" : "Play")
            Button { companion.perform(.next) } label: { Image(systemName: "forward.fill") }
                .help("Next").accessibilityLabel("Next")
        }
        .buttonStyle(.borderless)
        .font(.title2)
        .frame(maxWidth: .infinity)
        .disabled(!enabled)
    }
}

private struct Notice: View {
    let symbol: String
    let title: String
    let detail: String?
    let action: (String, () -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.secondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                if let detail { Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                if let action { Button(action.0, action: action.1).padding(.top, 2) }
            }
        }
    }
}

// MARK: - Connection and pairing

private struct ConnectionSection: View {
    let companion: Companion
    let relay: RelayAccount?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
                Text(text)
            }
            LabeledContent("iPhone") {
                Text(companion.pairedPhone?.name ?? "Not paired").foregroundStyle(.secondary)
            }
            if let relay {
                PairingControls(companion: companion, relay: relay)
            } else {
                Text("No relay set, so this Mac talks to a built-in mock relay.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var text: String {
        let status = companion.connection
        switch status.phase {
        case .connected: return "Connected to \(status.peerName ?? "relay")"
        case .connecting: return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        case .failed: return "Connection failed\(status.error.map { ": \($0.code)" } ?? "")"
        case .disconnected: return "Not connected"
        }
    }

    private var color: Color {
        switch companion.connection.phase {
        case .connected: .green
        case .connecting, .reconnecting: .yellow
        case .failed: .red
        case .disconnected: .secondary
        }
    }
}

/// Pairing with the relay: a code to type on the phone, then the person at the
/// Mac allows or refuses the phone that typed it (docs/relay/API-v1.md §4).
private struct PairingControls: View {
    let companion: Companion
    let relay: RelayAccount

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let request = companion.pairRequests.first {
                Text("“\(request.phone.name)” wants to show this Mac’s music.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Allow") { companion.decidePairing(request.claimID, approved: true); relay.clearPairingCode() }
                        .keyboardShortcut(.defaultAction)
                    Button("Don’t Allow") { companion.decidePairing(request.claimID, approved: false) }
                }
            } else if companion.pairedPhone != nil {
                // Paired: any code still on file was used up by the phone's claim.
                Button("Unpair iPhone") { Task { await relay.unpair() } }
            } else if let code = relay.pairingCode, code.expiresAt > Date() {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let left = max(0, Int(code.expiresAt.timeIntervalSince(context.date)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(code.code.map(String.init).joined(separator: " "))
                            .font(.system(.title, design: .monospaced).weight(.semibold))
                            .textSelection(.enabled)
                        Text(left > 0 ? "Type this in Music StandBy on your iPhone. Expires in \(left / 60):\(String(format: "%02d", left % 60))." : "Expired.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                Button("Pair iPhone…") { Task { await relay.requestPairingCode() } }
                    .disabled(!relay.isRegistered || companion.connection.phase != .connected)
            }
            if let error = relay.lastError {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct LaunchAtLoginRow: View {
    let launchAtLogin: LaunchAtLogin

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Launch at Login", isOn: Binding(get: { launchAtLogin.isEnabled }, set: { launchAtLogin.set($0) }))
            if let message = launchAtLogin.message {
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Stands in for the iPhone until the relay exists. Commands go through the
/// mock relay as wire JSON, the same path a real phone command will take.
private struct MockRelaySection: View {
    let companion: Companion
    let mock: MockRelayTransport

    var body: some View {
        DisclosureGroup("Simulate iPhone") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    ForEach(CommandKind.allCases, id: \.self) { kind in
                        Button(kind.rawValue.capitalized) { Task { await mock.simulateCommand(kind) } }
                    }
                }
                .controlSize(.small)
                if let message = companion.message {
                    Text("Last state: r\(String(message.revision)) · \(message.state.rawValue)")
                }
                if let ack = companion.lastAck {
                    Text("Last ack: \(ack.accepted ? "accepted" : ack.error?.code.rawValue ?? "rejected") · r\(String(ack.revision))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
        }
    }
}
