import os
import StandByKit
import SwiftUI
import UIKit

private let seekLog = Logger(subsystem: "com.alistairmerritt.MusicStandBy", category: "seekbar")

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(ReminderModel.self) private var reminders
    @State private var isConfirmingUnpair = false
    @State private var phoneMusic = SystemMusicPhonePlayer()
    /// Apple Music on this phone, read once a second while Home shows.
    @State private var phoneNowPlaying: PhoneNowPlaying?
    /// For the Continue Listening row: Apple Music access and subscription here.
    @State private var appleMusicAccess: AppleMusicAccess = .allowed
    @State private var canPlayCatalog: Bool?
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollViewReader { proxy in
        Form {
            if isDemoLayout { demoSection }

            Section("Now Playing on Mac") {
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
                } else {
                    Text("Nothing is playing on your Mac.")
                        .foregroundStyle(.secondary)
                }
            }

            if isDemoLayout {
                // Both directions need the real Mac's Music, so the demo only says what they do.
                Section("Continue Listening") {
                    Text("With Second Chair on your Mac, move what’s playing to Apple Music on this iPhone, and back again.")
                        .foregroundStyle(.secondary)
                }
            } else {
                HandoffSection(player: phoneMusic, here: $phoneNowPlaying, status: continueListening, allowAppleMusic: allowAppleMusic)
                    .id("continueListening")
            }
            nowPlayingSection
                .id("lockScreen")
            // The reminder comes from the relay, which the demo doesn't use.
            if !isDemoLayout { remindersSection }
            macSection

            Section {
                NavigationLink("Diagnostics") { DiagnosticsView() }
            }
        }
        .navigationTitle("Second Chair")
        .task {
            // Apple Music here has no change notice worth the wiring; once a
            // second is plenty for which handoff to offer.
            var tick = 0
            while !Task.isCancelled {
                phoneNowPlaying = phoneMusic.nowPlaying()
                let access = phoneMusic.access
                // The subscription once access is allowed, then every five minutes.
                if access != appleMusicAccess || tick % 300 == 0 { canPlayCatalog = await phoneMusic.canPlayCatalog() }
                appleMusicAccess = access
                tick += 1
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
        #if DEBUG
        .task {
            // -screenshotScroll continueListening|lockScreen: the lower part, for screenshots.
            guard let target = ScreenshotMode.scrollTarget else { return }
            try? await Task.sleep(for: .seconds(1))
            proxy.scrollTo(target, anchor: UnitPoint(x: 0.5, y: 0.08))
        }
        #endif
        }
    }

    /// Whether there's a session, or in a development build's screenshots
    /// what `-screenshotNowPlaying` asks for (the simulator has none).
    private var sessionIsActive: Bool {
        #if DEBUG
        if ScreenshotMode.nowPlayingState != nil { return true }
        #endif
        return model.sessionController.isActive
    }

    private var nowPlayingSection: some View {
        Section {
            // No status row: iOS's `isSystemPrimary` read false while Second
            // Chair was on the Lock Screen (8 and 17 November 2026), so
            // "Another app is showing" was wrong, and nothing else tells which
            // player shows. Diagnostics keeps the raw value.
            if sessionIsActive {
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
                Text("Get a silent reminder when your Mac starts playing again after a break. Tap it to bring Second Chair back to your Lock Screen and StandBy.")
                if let problem = reminders.problem {
                    Text(problem).foregroundStyle(.red)
                }
            }
        }
    }

    private var continueListening: ContinueListeningStatus? {
        ContinueListeningStatus.assess(mac: model.macMusicConnection, appleMusicAccess: appleMusicAccess, canPlayCatalog: canPlayCatalog)
    }

    /// Asks for Apple Music access, or, once refused, opens Settings.
    private func allowAppleMusic(canAsk: Bool) async {
        if canAsk {
            _ = await phoneMusic.requestAccess()
            appleMusicAccess = phoneMusic.access
            canPlayCatalog = await phoneMusic.canPlayCatalog()
        } else if let url = URL(string: UIApplication.openSettingsURLString) {
            openURL(url)
        }
    }

    /// The demo's own layout. Development builds' screenshots of the demo
    /// show a paired Mac's instead.
    private var isDemoLayout: Bool {
        #if DEBUG
        if ScreenshotMode.isOn { return false }
        #endif
        return model.isDemo
    }

    /// What the demo is, for App Review above all, and the way out.
    private var demoSection: some View {
        Section {
            Text("You’re trying Second Chair with a simulated Mac. Its songs are invented, and nothing plays aloud.")
            Button("Leave Demo") {
                Task { await model.leaveDemo() }
            }
        } header: {
            Text("Demo")
        } footer: {
            Text("Tap Show in Now Playing, then lock your iPhone or set it down to charge in StandBy.")
        }
    }

    /// The Mac alone: its buttons say what they act on, now that Continue
    /// Listening has a status of its own (16 November 2026).
    private var macSection: some View {
        Section("Mac") {
            LabeledContent("Name", value: model.pairedMac?.name ?? "")
            LabeledContent("Status", value: statusText)
            if !isDemoLayout {
                Button("Reconnect to Mac") {
                    Task { await model.reconnect() }
                }
                Button("Unpair Mac", role: .destructive) {
                    isConfirmingUnpair = true
                }
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
    @Environment(\.openURL) private var openURL
    let player: SystemMusicPhonePlayer
    @Binding var here: PhoneNowPlaying?
    /// Whether Continue Listening can work, and what to do if not. Nil when
    /// there's nothing to say yet.
    let status: ContinueListeningStatus?
    let allowAppleMusic: (_ canAsk: Bool) async -> Void
    @State private var working = false
    @State private var problem: String?
    /// Off unless turned on (17 November 2026), as adding changes the
    /// library: the Mac can only play a playlist or album that's in it.
    @AppStorage(HandoverMemory.addsToLibraryKey, store: UserDefaults(suiteName: AppGroup.identifier)) private var addsToLibrary = false

    private var macPlaying: Bool { model.attributes?.isPlaying == true }
    private var phonePlaying: Bool { here?.isPlaying == true }
    private var phoneSongInMacQueue: Bool { model.macQueuePosition(of: here?.catalogID) != nil }
    /// Any Apple Music song can go to the Mac: one its queue doesn't have goes as its station.
    private var phoneHasAppleMusicSong: Bool { here?.catalogID != nil }

    /// Whenever the Mac's song can move.
    private var showsContinueOnPhone: Bool { model.canContinueOnPhone }
    /// While the phone plays, or when its paused song is one the Mac has; not
    /// for whatever Apple Music here last played long ago.
    private var showsContinueOnMac: Bool { phonePlaying || phoneSongInMacQueue }

    /// Always shown once there's a status, so Continue Listening has a place
    /// on the phone even with nothing to continue (16 November 2026).
    var body: some View {
        if status != nil || showsContinueOnPhone || showsContinueOnMac {
            Section {
                if let status {
                    LabeledContent("Status", value: status.title)
                    if case .allowAppleMusic(let canAsk) = status {
                        Button(canAsk ? "Allow Apple Music Access" : "Open Settings") {
                            Task { await allowAppleMusic(canAsk) }
                        }
                    }
                }
                if showsContinueOnPhone {
                    row("Continue on iPhone", symbol: "iphone",
                        detail: model.macSongHasNoCatalogID
                            ? "Your iPhone will look this song up in Apple Music, then continue it here with your Up Next queue. Playback on your Mac will pause."
                            : "Continue listening on your iPhone, with your playlist, album or Up Next queue. Playback on your Mac will pause.",
                        enabled: !(phonePlaying && !macPlaying)) { await continueHere() }
                }
                if showsContinueOnMac {
                    row("Continue on Mac", symbol: "laptopcomputer",
                        detail: phoneSongInMacQueue
                            ? "Continue listening on your Mac from the same point. Playback on your iPhone will pause."
                            : "Continue listening on your Mac from the same point, with your playlist or album when your Mac can play it, or else this song’s station. Playback on your iPhone will pause.",
                        enabled: phoneHasAppleMusicSong && !(macPlaying && !phonePlaying)) { await sendBack() }
                }
            } header: {
                Text("Continue Listening")
            } footer: {
                if let problem { Text(problem) } else if let detail = status?.detail { Text(detail) }
            }
            .onChange(of: [macPlaying, phonePlaying]) { problem = nil }
            // Part of Continue Listening, so its short label reads in context.
            Section {
                Toggle("Automatically Add to Library", isOn: $addsToLibrary)
            } footer: {
                Text("To keep your playlist or album going when you Continue Listening from iPhone to Mac, Second Chair can add it to your Apple Music library automatically. It stays there until you remove it. With this off, your Mac plays the song’s station instead.")
            }
        }
    }

    private func continueHere() async -> String? {
        switch await model.continueOnPhone(with: player) {
        case .unavailable: return "This song couldn’t be found in Apple Music."
        case .notAllowed: return "Allow access to Apple Music in Settings to continue listening on your iPhone."
        case .didNotStart: return "Couldn’t start playback on your iPhone. Music is still playing on your Mac."
        case .continued, .macStillPlaying, .resumedHere, .alreadyPlayingHere:
            // The song is Apple Music's now: show it there.
            openURL(SystemMusicPhonePlayer.appURL)
            return nil
        }
    }

    private func sendBack() async -> String? {
        let outcome = await model.sendBackToMac(with: player)
        // Say only what's true now: headphones moving over can pause Apple Music here by themselves.
        let stillHere = player.nowPlaying()?.isPlaying == true ? " Music is still playing on your iPhone." : ""
        switch outcome {
        case .sentAsStation: return "Your Mac is playing the station, which started with another song."
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

/// The Continue Listening row's words (16 November 2026).
extension ContinueListeningStatus {
    var title: String {
        switch self {
        case .ready: "Ready"
        case .setUpOnMac: "Set Up on Your Mac"
        case .reconnectOnMac: "Reconnect on Your Mac"
        case .allowAppleMusic: "Allow Apple Music"
        case .needsAppleMusic: "Needs Apple Music"
        }
    }

    var detail: String? {
        switch self {
        case .ready:
            nil
        case .setUpOnMac:
            "Continue Listening needs Second Chair on your Mac connected to Music. On your Mac, click the music note and choose Connect to Music…, then select Second Chair under Devices in Music and enter the code."
        case .reconnectOnMac:
            "Music on your Mac no longer recognises Second Chair. On your Mac, click the music note and choose Connect to Music… again."
        case .allowAppleMusic:
            "Continue Listening plays songs in Apple Music on this iPhone, which Second Chair needs your permission for."
        case .needsAppleMusic:
            "Continue on iPhone plays the song in Apple Music on this iPhone, which needs an Apple Music subscription."
        }
    }
}
