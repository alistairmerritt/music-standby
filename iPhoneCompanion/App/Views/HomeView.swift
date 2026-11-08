import StandByKit
import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var isConfirmingUnpair = false

    var body: some View {
        Form {
            Section("Now Playing") {
                if let attributes = model.attributes, let track = attributes.track {
                    NowPlayingRow(track: track, attributes: attributes, artwork: model.artwork)
                    TransportControls(isPlaying: attributes.isPlaying) { kind in
                        Task { await model.send(kind) }
                    }
                } else {
                    Text("Nothing is playing on your Mac.")
                        .foregroundStyle(.secondary)
                }
            }

            nowPlayingSection
            macSection

            Section {
                NavigationLink("Diagnostics") { DiagnosticsView() }
            }
        }
        .navigationTitle("Music StandBy")
        .confirmationDialog("Unpair this Mac?", isPresented: $isConfirmingUnpair, titleVisibility: .visible) {
            Button("Unpair", role: .destructive) {
                Task { await model.unpair() }
            }
        } message: {
            Text("You’ll need a new pairing code to connect again.")
        }
    }

    private var nowPlayingSection: some View {
        Section {
            if model.sessionController.isActive {
                LabeledContent("Status", value: model.sessionController.isSystemPrimary ? "Primary Session" : "Not Primary")
                Button("Refresh Now Playing") {
                    Task { await model.activateNowPlaying() }
                }
                Button("Stop Showing", role: .destructive) {
                    Task { await model.stopNowPlaying() }
                }
            } else {
                Button("Show in Now Playing") {
                    Task { await model.activateNowPlaying() }
                }
                .disabled(model.attributes == nil)
            }
        } header: {
            Text("Lock Screen and StandBy")
        } footer: {
            Text("Music StandBy doesn’t play audio. Your Mac does.")
        }
    }

    private var macSection: some View {
        Section("Mac") {
            LabeledContent("Name", value: model.pairedMac?.name ?? "")
            LabeledContent("Status", value: statusText)
            Button("Reconnect") {
                Task { await model.reconnect() }
            }
            Button("Unpair", role: .destructive) {
                isConfirmingUnpair = true
            }
        }
    }

    private var statusText: String {
        switch model.connection {
        case .disconnected: "Not Connected"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .failed(let reason): reason
        }
    }
}

private struct NowPlayingRow: View {
    let track: SessionTrack
    let attributes: MacPlaybackAttributes
    let artwork: CGImage?

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                artworkView
                    .frame(width: 72, height: 72)
                    .clipShape(.rect(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title).font(.headline).lineLimit(1)
                    Text(track.artist).font(.subheadline).lineLimit(1)
                    Text(track.album).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = attributes.elapsed(at: context.date)
                VStack(spacing: 2) {
                    ProgressView(value: elapsed, total: max(track.duration, 1))
                    HStack {
                        Text(Duration.seconds(elapsed), format: .time(pattern: .minuteSecond))
                        Spacer()
                        Text(Duration.seconds(track.duration), format: .time(pattern: .minuteSecond))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var artworkView: some View {
        if let artwork {
            Image(decorative: artwork, scale: 1).resizable().scaledToFill()
        } else {
            Rectangle().fill(.quaternary)
                .overlay { Image(systemName: "music.note").foregroundStyle(.secondary) }
        }
    }
}

private struct TransportControls: View {
    let isPlaying: Bool
    let action: (CommandKind) -> Void

    var body: some View {
        HStack {
            Spacer()
            button("backward.fill", "Previous", .previous)
            Spacer()
            button(isPlaying ? "pause.fill" : "play.fill", isPlaying ? "Pause" : "Play", isPlaying ? .pause : .play)
                .font(.largeTitle)
            Spacer()
            button("forward.fill", "Next", .next)
            Spacer()
        }
        .font(.title2)
        .padding(.vertical, 4)
    }

    private func button(_ symbol: String, _ label: String, _ kind: CommandKind) -> some View {
        Button {
            action(kind)
        } label: {
            Label(label, systemImage: symbol).labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
    }
}
