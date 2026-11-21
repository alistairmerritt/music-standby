import StandByKit
import SwiftUI
import UIKit

/// Home: what's playing on the Mac, the remote, Continue Listening and the
/// Lock Screen button. Settings has the rest (21 November 2026 redesign; it
/// was one long Form until then).
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(OnboardingCoordinator.self) private var onboarding
    @State private var phoneMusic = SystemMusicPhonePlayer()
    /// Apple Music on this phone, read once a second while Home shows.
    @State private var phoneNowPlaying: PhoneNowPlaying?
    /// For Continue Listening: Apple Music access and subscription here.
    @State private var appleMusicAccess: AppleMusicAccess = .allowed
    @State private var canPlayCatalog: Bool?
    @Environment(\.openURL) private var openURL
    @State private var showsSettings = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if isDemoLayout { demoBanner }
                if !model.isDemo, !onboarding.progress.snapshot.playerHasShown { finishSetupBanner }
                if let connectionNotice { connectionNotice }

                NowPlayingPanel(attributes: attributes, mode: nowPlayingMode)

                VStack(spacing: 14) {
                    if isDemoLayout {
                        // Both directions need the real Mac's Music, so the demo only says what they do.
                        Notice(symbol: nil, title: nil,
                               text: "With Second Chair on your Mac, move what’s playing to Apple Music on this iPhone, and back again.",
                               button: nil, action: nil)
                    } else if isLive {
                        ContinueListeningArea(player: phoneMusic, here: $phoneNowPlaying, status: continueListening,
                                              allowAppleMusic: allowAppleMusic) {
                            onboarding.resume(.continueMusic)
                        }
                    }
                    ShowOnLockScreenButton(enabled: attributes != nil && isLive, sessionIsActive: sessionIsActive)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 32)
            .animation(.default, value: nowPlayingMode)
        }
        .navigationTitle("Second Chair")
        .navigationSubtitle(connectionSummary)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Settings", systemImage: "gearshape") { showsSettings = true }
            }
        }
        .navigationDestination(isPresented: $showsSettings) { SettingsView() }
        #if DEBUG
        .onAppear { if ProcessInfo.processInfo.arguments.contains("-screenshotSettings") { showsSettings = true } }
        #endif
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
    }

    // MARK: State

    private var connection: ConnectionState {
        #if DEBUG
        if let state = HomeScreenshot.connection { return state }
        #endif
        return model.connection
    }

    private var attributes: MacPlaybackAttributes? {
        #if DEBUG
        if HomeScreenshot.nothingPlaying { return nil }
        #endif
        return model.attributes
    }

    /// The Mac's state is current. Not while it's offline or the relay is
    /// unreachable: then the panel shows the last song without controls.
    private var isLive: Bool {
        switch connection {
        case .macOffline, .disconnected, .failed: false
        case .connected, .connecting, .reconnecting: true
        }
    }

    private var nowPlayingMode: NowPlayingMode {
        if !isLive { return .lastKnown }
        guard iPhoneIsPlaying else { return .live }
        return iPhoneHasMacSong ? .onIPhone : .iPhonePlaysOther(phoneNowPlaying?.title)
    }

    /// Apple Music on this iPhone plays while the Mac doesn't (17 November
    /// 2026). Read once a second, like the rest of Home's view of it.
    private var iPhoneIsPlaying: Bool {
        guard attributes?.isPlaying != true else { return false }
        #if DEBUG
        if ScreenshotMode.iPhonePlaying { return true }
        #endif
        return phoneNowPlaying?.isPlaying == true
    }

    /// The iPhone plays the Mac's current song, as Continue on iPhone leaves it.
    private var iPhoneHasMacSong: Bool {
        #if DEBUG
        if ScreenshotMode.iPhonePlaying { return true }
        #endif
        return model.macQueuePosition(of: phoneNowPlaying?.catalogID) == 0
    }

    /// Whether there's a session, or in a development build's screenshots
    /// what `-screenshotNowPlaying` asks for (the simulator has none).
    private var sessionIsActive: Bool {
        #if DEBUG
        if ScreenshotMode.nowPlayingState != nil { return true }
        #endif
        return model.sessionController.isActive
    }

    private var continueListening: ContinueListeningStatus? {
        #if DEBUG
        if let status = HomeScreenshot.continueListening { return status }
        #endif
        return ContinueListeningStatus.assess(mac: model.macMusicConnection, appleMusicAccess: appleMusicAccess, canPlayCatalog: canPlayCatalog)
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

    // MARK: Connection

    /// "MacBook Pro · Connected", under the title.
    private var connectionSummary: Text {
        let name = model.pairedMac?.name ?? "Your Mac"
        if isDemoLayout { return Text("\(name) · Simulated") }
        return Text("\(name) · \(connection.summary)")
    }

    /// Only when the Mac can't be reached: what to do, and Reconnect.
    private var connectionNotice: Notice? {
        guard !isDemoLayout else { return nil }
        let reconnect = { Task { await model.reconnect() } }
        return switch connection {
        case .macOffline:
            Notice(symbol: "moon.zzz", title: "\(model.pairedMac?.name ?? "Your Mac") is offline.",
                   text: "Wake your Mac and check Second Chair is open on it.",
                   button: "Reconnect") { _ = reconnect() }
        case .disconnected:
            Notice(symbol: "wifi.slash", title: "Not connected.",
                   text: "Check this iPhone is online, then reconnect.",
                   button: "Reconnect") { _ = reconnect() }
        case .failed(let reason):
            Notice(symbol: "exclamationmark.triangle", title: "Can’t connect.", text: reason,
                   button: "Reconnect") { _ = reconnect() }
        case .connected, .connecting, .reconnecting:
            nil
        }
    }

    // MARK: Banners

    /// What the demo is, for App Review above all, and the way out.
    private var demoBanner: some View {
        Notice(symbol: "sparkles", title: "Demo",
               text: "You’re trying a simulated Mac. Its songs are invented, and nothing plays aloud. Tap Show on Lock Screen, then lock your iPhone or stand it on a charger for StandBy.",
               button: "Leave Demo") { Task { await model.leaveDemo() } }
    }

    /// Until the player has shown once: the first run, from where it stopped.
    private var finishSetupBanner: some View {
        Notice(symbol: "checklist", title: "Finish setting up",
               text: "Play something on \(model.pairedMac?.name ?? "your Mac"). Your music shows up here and on your Lock Screen once it’s playing.",
               button: "Continue") { onboarding.resume(.play) }
    }
}

extension ConnectionState {
    /// The short state after the Mac's name, on Home and in Settings.
    var summary: String {
        switch self {
        case .disconnected: "Not Connected"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .macOffline: "Offline"
        case .reconnecting: "Reconnecting…"
        case .failed: "Can’t Connect"
        }
    }
}

/// Shows the Mac's music on the Lock Screen, in StandBy and in Control
/// Centre: asks iOS again, which is also how a dismissed player comes back.
/// A long press offers Stop Showing, which Settings has too.
///
/// No "showing" status anywhere: iOS's `isSystemPrimary` read false while
/// Second Chair was on the Lock Screen (8 and 17 November 2026).
private struct ShowOnLockScreenButton: View {
    @Environment(AppModel.self) private var model
    let enabled: Bool
    let sessionIsActive: Bool

    var body: some View {
        Menu {
            Button("Stop Showing", systemImage: "eye.slash") {
                Task { await model.stopNowPlaying() }
            }
            .disabled(!sessionIsActive)
        } label: {
            Label("Show on Lock Screen", systemImage: "lock.iphone")
                .frame(maxWidth: .infinity)
        } primaryAction: {
            Task { await model.activateNowPlaying() }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .tint(.primary)
        .disabled(!enabled)
        .accessibilityHint("Shows your Mac’s music on the Lock Screen, in StandBy and in Control Centre. Use it if you dismissed the player.")
    }
}

#if DEBUG
/// `-screenshotHome offline|nothing|notSetUp|access|disconnected`: Home in a
/// state the simulated Mac can't reach by itself, for screenshots.
@MainActor
enum HomeScreenshot {
    static var state: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let at = arguments.firstIndex(of: "-screenshotHome"), arguments.count > at + 1 else { return nil }
        return arguments[at + 1]
    }

    static var connection: ConnectionState? {
        switch state {
        case "offline": .macOffline(macName: "MacBook Pro")
        case "disconnected": .disconnected
        case "reconnecting": .reconnecting
        default: nil
        }
    }

    static var nothingPlaying: Bool { state == "nothing" }

    static var continueListening: ContinueListeningStatus? {
        switch state {
        case "notSetUp": .setUpOnMac
        case "access": .allowAppleMusic(canAsk: true)
        case "noSubscription": .needsAppleMusic
        // The simulator can't grant Apple Music: screenshots show it ready.
        default: ScreenshotMode.isOn ? .ready : nil
        }
    }
}
#endif
