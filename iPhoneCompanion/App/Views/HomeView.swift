import os
import StandByKit
import SwiftUI

private let seekLog = Logger(subsystem: "com.alistairmerritt.MusicStandBy", category: "seekbar")

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(ReminderModel.self) private var reminders
    @State private var isConfirmingUnpair = false
    @State private var phoneMusic = SystemMusicPhonePlayer()
    /// Apple Music on this phone, read once a second while Home shows.
    @State private var phoneNowPlaying: PhoneNowPlaying?

    var body: some View {
        Form {
            Section("Now Playing") {
                if let attributes = model.attributes, let track = attributes.track {
                    NowPlayingRow(track: track, attributes: attributes, artwork: model.artwork) { seconds in
                        Task { await model.seek(to: seconds) }
                    }
                    TransportControls(isPlaying: attributes.isPlaying) { kind in
                        Task { await model.send(kind) }
                    }
                    if let volume = attributes.volume {
                        VolumeRow(level: volume) { level in
                            Task { await model.setVolume(level) }
                        }
                    }
                    if !model.outputs.isEmpty {
                        OutputPicker(outputs: model.outputs) { id in
                            Task { await model.selectOutput(id) }
                        }
                    }
                } else {
                    Text("Nothing is playing on your Mac.")
                        .foregroundStyle(.secondary)
                }
            }

            HandoffSection(player: phoneMusic, here: $phoneNowPlaying)
            nowPlayingSection
            remindersSection
            macSection

            Section {
                NavigationLink("Diagnostics") { DiagnosticsView() }
            }
        }
        .navigationTitle("Second Chair")
        .task {
            // Apple Music here has no change notice worth the wiring; once a
            // second is plenty for which handoff to offer.
            while !Task.isCancelled {
                phoneNowPlaying = phoneMusic.nowPlaying()
                try? await Task.sleep(for: .seconds(1))
            }
        }
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
            // iOS shows a session only once the app has asked while open, so a
            // dismissed player stays hidden until the next launch re-requests it.
            Text("If you dismiss the player, it stays hidden until you next open Second Chair.")
        }
    }

    private var remindersSection: some View {
        Section {
            Toggle("Remind When Music Starts", isOn: Binding(
                get: { reminders.isEnabled },
                set: { enabled in Task { await reminders.setEnabled(enabled) } }
            ))
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("If you’ve dismissed Second Chair from your Lock Screen or StandBy, get a silent notification when your Mac starts playing music again. It shows during a Focus too. Tap it to bring the player back.")
                if let problem = reminders.problem {
                    Text(problem).foregroundStyle(.red)
                }
            }
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
        case .macOffline: "Mac Offline"
        case .reconnecting: "Reconnecting…"
        case .failed(let reason): reason
        }
    }
}

private struct NowPlayingRow: View {
    let track: SessionTrack
    let attributes: MacPlaybackAttributes
    let artwork: CGImage?
    /// Called once when a drag on the progress bar ends, with the chosen position.
    let onSeek: (TimeInterval) -> Void

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
            SeekBar(attributes: attributes, duration: track.duration, onSeek: onSeek)
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

/// The progress bar, draggable. While dragging it shows the finger's position;
/// when the drag ends the Mac is asked to seek there, and the bar goes back to
/// following the Mac's own state until the result arrives.
///
/// The end of a drag is taken from `onEditingChanged(false)` **or** from the
/// values going quiet for `settle`: on an iPhone (12 Nov 2026) a drag on this
/// slider reported its start and every value but never its end, with or
/// without the clock running, while the volume slider below always did. The
/// clock also pauses during a drag.
private struct SeekBar: View {
    let attributes: MacPlaybackAttributes
    let duration: TimeInterval
    let onSeek: (TimeInterval) -> Void
    @State private var dragging = false
    @State private var dragValue: TimeInterval = 0
    @State private var now = Date()
    @State private var settling: Task<Void, Never>?
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private static let settle: Duration = .milliseconds(600)

    var body: some View {
        let elapsed = dragging ? dragValue : attributes.elapsed(at: now)
        VStack(spacing: 2) {
            Slider(
                value: Binding(get: { elapsed }, set: { value in
                    dragValue = value
                    if !dragging { dragging = true }
                    settling?.cancel()
                    settling = Task { @MainActor in
                        try? await Task.sleep(for: Self.settle)
                        guard !Task.isCancelled else { return }
                        finishDrag()
                    }
                }),
                in: 0...max(duration, 1),
                onEditingChanged: { editing in
                    if editing {
                        dragValue = elapsed
                        dragging = true
                    } else {
                        settling?.cancel()
                        finishDrag()
                    }
                }
            )
            .disabled(duration <= 0)
            HStack {
                Text(Duration.seconds(elapsed), format: .time(pattern: .minuteSecond))
                Spacer()
                Text(Duration.seconds(duration), format: .time(pattern: .minuteSecond))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .onReceive(clock) { if !dragging { now = $0 } }
    }

    private func finishDrag() {
        guard dragging else { return }
        seekLog.debug("Seek bar drag ended, seeking to \(dragValue, privacy: .public)")
        dragging = false
        now = Date()
        onSeek(dragValue)
    }
}

/// Its own box under Now Playing, with both directions. Each is greyed out
/// while the music is already on that side; with both paused, both work.
private struct HandoffSection: View {
    @Environment(AppModel.self) private var model
    let player: SystemMusicPhonePlayer
    @Binding var here: PhoneNowPlaying?
    @State private var working = false
    @State private var problem: String?

    private var macPlaying: Bool { model.attributes?.isPlaying == true }
    private var phonePlaying: Bool { here?.isPlaying == true }
    private var phoneSongInMacQueue: Bool { model.macQueuePosition(of: here?.catalogID) != nil }

    /// Whenever the Mac's song can move.
    private var showsContinueOnPhone: Bool { model.canContinueOnPhone }
    /// While the phone plays, or when its paused song is one the Mac has; not
    /// for whatever Apple Music here last played long ago.
    private var showsContinueOnMac: Bool { phonePlaying || phoneSongInMacQueue }

    var body: some View {
        if showsContinueOnPhone || showsContinueOnMac {
            Section {
                if showsContinueOnPhone {
                    row("Continue on iPhone", symbol: "iphone",
                        detail: "Continue listening on your iPhone, including your Up Next queue. Playback on your Mac will pause.",
                        enabled: !(phonePlaying && !macPlaying)) { await continueHere() }
                }
                if showsContinueOnMac {
                    row("Continue on Mac", symbol: "laptopcomputer",
                        detail: phoneSongInMacQueue
                            ? "Continue listening on your Mac from the same point. Playback on your iPhone will pause."
                            : "This song is no longer available in your Mac’s queue.",
                        enabled: phoneSongInMacQueue && !(macPlaying && !phonePlaying)) { await sendBack() }
                }
            } header: {
                Text("Continue Listening")
            } footer: {
                if let problem { Text(problem) }
            }
            .onChange(of: [macPlaying, phonePlaying]) { problem = nil }
        }
    }

    private func continueHere() async -> String? {
        switch await model.continueOnPhone(with: player) {
        case .unavailable: "This song couldn’t be found in Apple Music."
        case .notAllowed: "Allow access to Apple Music in Settings to continue listening on your iPhone."
        case .didNotStart: "Couldn’t start playback on your iPhone. Music is still playing on your Mac."
        case .continued, .macStillPlaying: nil
        }
    }

    private func sendBack() async -> String? {
        let outcome = await model.sendBackToMac(with: player)
        // Say only what's true now: headphones moving over can pause Apple Music here by themselves.
        let stillHere = player.nowPlaying()?.isPlaying == true ? " Music is still playing on your iPhone." : ""
        switch outcome {
        case .notInMacQueue: return "This song is no longer in your Mac’s queue."
        case .macRefused: return "Couldn’t start playback on your Mac." + stillHere
        case .macDidNotStart: return "Your Mac didn’t respond. Try again." + stillHere
        case .sentBack, .nothingPlayingHere: return nil
        }
    }

    private func row(_ title: String, symbol: String, detail: String, enabled: Bool,
                     action: @escaping @MainActor () async -> String?) -> some View {
        Button {
            Task {
                working = true
                problem = nil
                problem = await action()
                here = player.nowPlaying()
                working = false
            }
        } label: {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).foregroundStyle(enabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                        Text(detail).font(.footnote).foregroundStyle(enabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.quaternary))
                    }
                } icon: {
                    Image(systemName: symbol).foregroundStyle(enabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                }
                if working {
                    Spacer()
                    ProgressView()
                }
            }
        }
        // iOS's own dimming of a disabled row is too faint here: set the
        // colours, so a direction that isn't open looks it.
        .disabled(working || !enabled)
    }
}

/// Music's own volume on the Mac. Sent once when the drag ends.
private struct VolumeRow: View {
    let level: Double
    let onChange: (Double) -> Void
    @State private var dragging = false
    @State private var dragValue = 0.0

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill").foregroundStyle(.secondary)
            Slider(
                value: Binding(get: { dragging ? dragValue : level }, set: { dragValue = $0 }),
                in: 0...1,
                onEditingChanged: { editing in
                    if editing {
                        dragValue = level
                    } else {
                        onChange(dragValue)
                    }
                    dragging = editing
                }
            )
            Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
        }
        .accessibilityLabel("Volume on your Mac")
    }
}

/// Where the Mac plays to. Choosing one sends Music there alone.
private struct OutputPicker: View {
    let outputs: [AudioOutput]
    let onSelect: (String) -> Void

    private var selectedID: String { outputs.first { $0.isSelected }?.id ?? "" }

    var body: some View {
        Picker("Play To", selection: Binding(get: { selectedID }, set: { id in
            if id != selectedID, !id.isEmpty { onSelect(id) }
        })) {
            ForEach(outputs) { output in
                Label(output.name, systemImage: symbol(for: output.kind))
                    .tag(output.id)
                    .disabled(!output.isAvailable)
            }
        }
    }

    private func symbol(for kind: AudioOutput.Kind) -> String { kind.symbolName }
}

extension AudioOutput.Kind {
    /// Also the Shortcuts speaker picker's.
    var symbolName: String {
        switch self {
        case .computer: "laptopcomputer"
        case .homePod: "homepod.fill"
        case .appleTV, .tv: "appletv.fill"
        case .bluetooth: "headphones"
        default: "airplayaudio"
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
