import AppKit
import CompanionCore
import StandByProtocol
import SwiftUI

// The menu bar panel, drawn from plain values (`MenuModel`) so every state can
// be rendered for review without a live Companion (21 November 2026 redesign:
// compact listening panel, one setup card at a time, a status footer with a
// gear menu instead of permanent settings sections).

/// What the panel shows. `MenuContent` builds it from the live companion.
struct MenuModel {
    enum Music {
        case checking
        case notRunning
        case automationDenied
        case slow
        case readError(String?)
        case nothing
        case track(TrackInfo)
    }

    struct TrackInfo {
        var title: String
        var artist: String
        var album: String
        var artwork: Data?
        var state: PlaybackState
        var duration: TimeInterval?
        var elapsed: (Date) -> TimeInterval
    }

    /// At most one at a time, under the song.
    enum Setup {
        case confirmUnpair
        case pairRequest(phoneName: String)
        case pairCode(code: String, expiresAt: Date)
        case pairStart(enabled: Bool)
        case musicCode(String)
        case musicForgotten
        case musicFailed(String)
        case musicJustConnected
        case continueListeningNotSetUp
        case launchTip
    }

    enum MusicLink { case connected, notConnected, connecting, forgotten, failed }

    var music: Music
    var handedOver = false
    var offersContinueFromPhone = false
    var handBack: HandBackProgress?
    var setup: Setup?
    var relayError: String?
    var launchMessage: String?
    var phase: ConnectionStatus.Phase
    var failureCode: String?
    var phonePaired: Bool
    var hasRelay = true
    var launchAtLogin: Bool
    var musicLink: MusicLink
    var version: String
}

/// What the panel's buttons do.
struct MenuActions {
    var transport: (MusicCommand) -> Void = { _ in }
    var continueFromPhone: () -> Void = {}
    var openMusic: () -> Void = {}
    var openPrivacySettings: () -> Void = {}
    var pairIPhone: () -> Void = {}
    var allow: () -> Void = {}
    var dontAllow: () -> Void = {}
    var askToUnpair: () -> Void = {}
    var unpair: () -> Void = {}
    var cancelUnpair: () -> Void = {}
    var connectToMusic: () -> Void = {}
    var cancelMusicCode: () -> Void = {}
    var disconnectFromMusic: () -> Void = {}
    var dismissContinueListening: () -> Void = {}
    var setLaunchAtLogin: (Bool) -> Void = { _ in }
    var dismissLaunchTip: () -> Void = {}
    var quit: () -> Void = {}
}

struct MenuLayout<Extra: View>: View {
    let model: MenuModel
    let actions: MenuActions
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            NowPlayingArea(model: model, actions: actions)
            if model.offersContinueFromPhone {
                ContinueFromPhoneArea(handedOver: model.handedOver, progress: model.handBack, action: actions.continueFromPhone)
            }
            if let setup = model.setup {
                SetupCard(setup: setup, actions: actions)
                    .transition(.opacity)
            }
            if let message = model.launchMessage {
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.relayError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            extra()
            StatusFooter(model: model, actions: actions)
        }
        .padding(16)
        .frame(width: 320)
        .animation(.default, value: model.setupKey)
        // ⌘Q from anywhere in the panel, not only inside the gear menu.
        .background {
            Button("", action: actions.quit).keyboardShortcut("q").opacity(0).accessibilityHidden(true)
        }
    }
}

private extension MenuModel {
    /// For animating the setup card in and out.
    var setupKey: String {
        guard let setup else { return "" }
        return String(describing: setup).components(separatedBy: "(").first ?? ""
    }
}

// MARK: - Now playing

private struct NowPlayingArea: View {
    let model: MenuModel
    let actions: MenuActions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(MacMenuText.onThisMac.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            switch model.music {
            case .checking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking Music…").foregroundStyle(.secondary)
                }
            case .notRunning:
                ProblemNotice(symbol: "music.note", title: "Music isn’t running",
                              detail: "Second Chair never opens Music by itself.",
                              button: ("Open Music", actions.openMusic))
            case .automationDenied:
                ProblemNotice(symbol: "exclamationmark.triangle", title: "Second Chair can’t read Music",
                              detail: "Allow it in System Settings › Privacy & Security › Automation.",
                              button: ("Open Privacy Settings", actions.openPrivacySettings))
            case .slow:
                ProblemNotice(symbol: "hourglass", title: "Music is slow to respond",
                              detail: "Quitting and reopening Music usually fixes this.", button: nil)
            case .readError(let detail):
                ProblemNotice(symbol: "music.note", title: "Can’t read Music right now", detail: detail, button: nil)
            case .nothing:
                HStack(spacing: 12) {
                    Artwork(data: nil)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Nothing playing").font(.headline)
                        Text("Play something in Music.").font(.callout).foregroundStyle(.secondary)
                    }
                }
            case .track(let track):
                TrackArea(track: track, handedOver: model.handedOver, transport: actions.transport)
            }
        }
    }
}

private struct TrackArea: View {
    let track: MenuModel.TrackInfo
    let handedOver: Bool
    let transport: (MusicCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Artwork(data: track.artwork)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title).font(.headline).lineLimit(2).truncationMode(.tail)
                    Text(track.artist).lineLimit(1)
                    Text(track.album).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    Group {
                        if handedOver {
                            // What this Mac did last, not what the phone plays now:
                            // the Mac can't see the phone.
                            Label("Continued on iPhone", systemImage: "iphone")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(.fill.tertiary, in: .capsule)
                        } else {
                            Text(stateText).font(.caption)
                        }
                    }
                    .foregroundStyle(.secondary)
                    .padding(.top, 3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            if let duration = track.duration, duration > 0 {
                ProgressBar(duration: duration, elapsed: track.elapsed)
            }
            TransportRow(state: track.state, action: transport)
        }
    }

    private var stateText: String {
        switch track.state {
        case .playing: "Playing"
        case .paused: "Paused"
        default: "Stopped"
        }
    }
}

private struct Artwork: View {
    let data: Data?

    var body: some View {
        Group {
            if let data, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary)
                    .overlay(Image(systemName: "music.note").font(.title2).foregroundStyle(.secondary))
            }
        }
        .frame(width: 76, height: 76)
        .clipShape(.rect(cornerRadius: 8))
        // A hairline, so a dark cover keeps its edge in dark mode.
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}

/// Display only, extrapolated as the phone does. Quieter than before.
private struct ProgressBar: View {
    let duration: TimeInterval
    let elapsed: (Date) -> TimeInterval

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = min(max(0, elapsed(context.date)), duration)
            VStack(spacing: 3) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule().fill(.secondary).frame(width: geometry.size.width * now / duration)
                    }
                }
                .frame(height: 4)
                HStack {
                    Text(Self.format(now))
                    Spacer()
                    Text("−" + Self.format(duration - now))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(Self.format(now)) of \(Self.format(duration))")
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds).rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct TransportRow: View {
    let state: PlaybackState
    let action: (MusicCommand) -> Void

    var body: some View {
        let enabled = state == .playing || state == .paused
        HStack(spacing: 36) {
            button("backward.fill", "Previous", .previous, size: 15)
            button(state == .playing ? "pause.fill" : "play.fill", state == .playing ? "Pause" : "Play", .playPause, size: 22)
            button("forward.fill", "Next", .next, size: 15)
        }
        .frame(maxWidth: .infinity)
        .disabled(!enabled)
    }

    private func button(_ symbol: String, _ label: String, _ kind: MusicCommand, size: CGFloat) -> some View {
        Button { action(kind) } label: {
            Image(systemName: symbol)
                .font(.system(size: size))
                .frame(width: 32, height: 28)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// A Music-side problem, in place of the song, with its fix.
private struct ProblemNotice: View {
    let symbol: String
    let title: String
    let detail: String?
    let button: (String, () -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.secondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                if let detail {
                    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let button {
                    Button(button.0, action: button.1).buttonStyle(.bordered).padding(.top, 4)
                }
            }
        }
    }
}

// MARK: - Continue from iPhone

private struct ContinueFromPhoneArea: View {
    let handedOver: Bool
    let progress: HandBackProgress?
    let action: () -> Void

    var body: some View {
        let waiting = progress?.isWaiting ?? false
        VStack(spacing: 8) {
            Button(action: action) {
                HStack(spacing: 6) {
                    if waiting, progress?.kind == .progress {
                        ProgressView().controlSize(.small)
                        Text(progress?.message ?? "Asking your iPhone…")
                    } else {
                        Label(MacMenuText.continueFromIPhone, systemImage: "iphone.and.arrow.forward")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .modifier(Prominence(prominent: handedOver))
            .disabled(waiting)
            if let progress, let message = progress.message, progress.kind != .progress {
                ResultLine(kind: progress.kind, text: message)
            }
        }
    }
}

private struct Prominence: ViewModifier {
    let prominent: Bool
    func body(content: Content) -> some View {
        if prominent { content.buttonStyle(.borderedProminent) } else { content.buttonStyle(.bordered) }
    }
}

private struct ResultLine: View {
    let kind: HandBackProgress.Kind
    let text: String

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
        .font(.callout)
        .foregroundStyle(kind == .info ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var symbol: String {
        switch kind {
        case .waitingOnYou: "bell.badge"
        case .info: "info.circle"
        case .failed: "exclamationmark.triangle.fill"
        case .progress: "ellipsis"
        }
    }

    private var color: Color {
        switch kind {
        case .waitingOnYou: .accentColor
        case .info: .secondary
        case .failed: .orange
        case .progress: .secondary
        }
    }
}

extension HandBackProgress {
    /// How the menu shows this request's line (21 November 2026).
    enum Kind { case progress, waitingOnYou, info, failed }

    var kind: Kind {
        if timedOut { return .failed }
        // The library dialog is open: a spinner, not a result (28 November 2026).
        if askingYou { return .progress }
        switch status {
        case nil, .asked?, .working?, .done?: return .progress
        case .notified?: return .waitingOnYou
        case .nothingPlaying?, .notInQueue?, .needsLibraryChoice?, .cancelled?: return .info
        default: return .failed
        }
    }
}

// MARK: - Setup cards

private struct SetupCard: View {
    let setup: MenuModel.Setup
    let actions: MenuActions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quaternary, in: .rect(cornerRadius: 10))
    }

    @ViewBuilder private var content: some View {
        switch setup {
        case .confirmUnpair:
            title("iphone.slash", "Unpair this iPhone?")
            note("You’ll need to pair it again to use Second Chair.")
            HStack {
                Spacer()
                Button(MacMenuText.cancel, action: actions.cancelUnpair).keyboardShortcut(.cancelAction)
                Button(MacMenuText.unpairIPhone, role: .destructive, action: actions.unpair)
            }
        case .pairRequest(let phoneName):
            title("iphone", MacMenuText.wantsToShow(phoneName))
            HStack {
                Spacer()
                Button(MacMenuText.dontAllow, action: actions.dontAllow)
                Button(MacMenuText.allow, action: actions.allow).keyboardShortcut(.defaultAction)
            }
        case .pairCode(let code, let expiresAt):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = max(0, Int(expiresAt.timeIntervalSince(context.date)))
                VStack(alignment: .leading, spacing: 6) {
                    label("iphone", "iPhone pairing code")
                    if left > 0 {
                        Text(Self.grouped(code, by: 3))
                            .font(.system(size: 28, weight: .semibold, design: .monospaced))
                            .textSelection(.enabled)
                            .accessibilityLabel(code.map(String.init).joined(separator: " "))
                        note("\(MacMenuText.typeThisOnIPhone) Expires in \(left / 60):\(String(format: "%02d", left % 60)).")
                    } else {
                        note("Expired.")
                        Button(MacMenuText.pairIPhone, action: actions.pairIPhone)
                    }
                }
            }
        case .pairStart(let enabled):
            title("iphone", "Pair your iPhone.")
            note("Open Second Chair on your iPhone, then pair it with this Mac.")
            Button(MacMenuText.pairIPhone, action: actions.pairIPhone)
                .buttonStyle(.borderedProminent)
                .disabled(!enabled)
        case .musicCode(let code):
            label("music.note.house", "Music connection code")
            note(MacMenuText.musicCodeNote)
            HStack(alignment: .firstTextBaseline) {
                Text(code)
                    .font(.system(size: 28, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                    .accessibilityLabel(code.map(String.init).joined(separator: " "))
                Spacer()
                Button(MacMenuText.cancel, action: actions.cancelMusicCode)
            }
        case .musicForgotten:
            title("music.note.house", "Music no longer recognises Second Chair.")
            note("Connect again so your music can move between this Mac and your iPhone.")
            Button(MacMenuText.connectToMusic, action: actions.connectToMusic)
        case .musicFailed(let message):
            title("music.note.house", message)
            Button("Try Again", action: actions.connectToMusic)
        case .musicJustConnected:
            Label {
                Text(MacMenuText.connectedToMusicNote).font(.callout).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        case .continueListeningNotSetUp:
            title("music.note.house", "Continue Listening isn’t set up.")
            note("Connect to Music to keep your playlist or Up Next queue when your music moves between this Mac and your iPhone.")
            HStack {
                Button(MacMenuText.connectToMusic, action: actions.connectToMusic)
                Spacer()
                Button("Not Now", action: actions.dismissContinueListening).buttonStyle(.link)
            }
        case .launchTip:
            title("power", "Keep Second Chair running when you log in?")
            HStack {
                Button("Turn On") { actions.setLaunchAtLogin(true) }
                Spacer()
                Button("Not Now", action: actions.dismissLaunchTip).buttonStyle(.link)
            }
        }
    }

    private func title(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).font(.headline).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary)
        }
    }

    private func label(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    /// "482 916": six digits in two groups, so they don't look like Music's four.
    static func grouped(_ code: String, by size: Int) -> String {
        stride(from: 0, to: code.count, by: size).map { start in
            let from = code.index(code.startIndex, offsetBy: start)
            let to = code.index(from, offsetBy: min(size, code.count - start))
            return String(code[from..<to])
        }.joined(separator: " ")
    }
}

// MARK: - Footer

private struct StatusFooter: View {
    let model: MenuModel
    let actions: MenuActions

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
                Text("\(word) · \(model.phonePaired ? "iPhone paired" : "No iPhone paired")")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                gear
            }
            .accessibilityElement(children: .contain)
            if model.phase == .failed || model.phase == .disconnected, model.hasRelay {
                Text("Second Chair can’t reach its server. Check this Mac’s internet connection.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var word: String {
        switch model.phase {
        case .connected: "Online"
        case .connecting: "Connecting…"
        case .reconnecting: "Reconnecting…"
        case .failed, .disconnected: "Offline"
        }
    }

    private var color: Color {
        switch model.phase {
        case .connected: .green
        case .connecting, .reconnecting: .orange
        case .failed, .disconnected: .red
        }
    }

    private var gear: some View {
        Menu {
            Toggle("Launch at Login", isOn: Binding(get: { model.launchAtLogin }, set: actions.setLaunchAtLogin))
            Divider()
            Text(model.phonePaired ? "iPhone: Paired" : "iPhone: Not Paired")
            if model.hasRelay {
                if model.phonePaired {
                    Button("Unpair iPhone…", action: actions.askToUnpair)
                } else {
                    Button(MacMenuText.pairIPhone, action: actions.pairIPhone)
                }
            }
            Divider()
            Text(musicLine)
            switch model.musicLink {
            case .connected: Button("Disconnect from Music", action: actions.disconnectFromMusic)
            case .connecting: Button("Cancel Connecting to Music", action: actions.cancelMusicCode)
            case .notConnected, .forgotten, .failed: Button(MacMenuText.connectToMusic, action: actions.connectToMusic)
            }
            Divider()
            Text(serverLine)
            Link("Second Chair Guide", destination: URL(string: "https://madewithmerritt.com/second-chair/guide/")!)
            Link("Getting Started", destination: URL(string: "https://madewithmerritt.com/second-chair/getting-started/")!)
            Text(model.version)
            Divider()
            Button("Quit Second Chair", action: actions.quit).keyboardShortcut("q")
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Settings")
        .accessibilityLabel("Settings")
    }

    private var musicLine: String {
        switch model.musicLink {
        case .connected: "Music: Connected for Continue Listening"
        case .connecting: "Music: Waiting for the code"
        case .notConnected: "Music: Not Connected"
        case .forgotten: "Music: Needs Reconnecting"
        case .failed: "Music: Couldn’t Connect"
        }
    }

    private var serverLine: String {
        let base = "Server: \(word)"
        guard let code = model.failureCode else { return base }
        return "\(base) (\(code))"
    }
}
