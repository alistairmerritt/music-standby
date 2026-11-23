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
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if isDemoLayout { demoBanner }
                if !model.isDemo, !onboarding.progress.snapshot.playerHasShown { finishSetupBanner }
                ConnectionCard(macName: model.pairedMac?.name ?? "Your Mac", connection: connection, isDemo: isDemoLayout) {
                    Task { await model.reconnect() }
                }

                NowPlayingPanel(attributes: attributes, mode: nowPlayingMode)

                VStack(spacing: 14) {
                    if isDemoLayout {
                        // Both directions need the real Mac's Music, so the demo only says what they do.
                        Notice(symbol: nil, title: nil,
                               text: "With Second Chair on your Mac, move what’s playing to Apple Music on this iPhone, and back again.",
                               button: nil, action: nil)
                    } else if isLive {
                        ContinueListeningArea(player: phoneMusic, here: $phoneNowPlaying, status: continueListening,
                                              allowAppleMusic: allowAppleMusic,
                                              setUp: { onboarding.resume(.continueMusic) },
                                              quiet: nowPlayingMode == .onIPhone)
                    }
                    // Apple Music has the Lock Screen while it plays the Mac's
                    // song here, so the Mac's player has nothing to show; Stop
                    // Showing is still in Settings (23 November 2026).
                    if nowPlayingMode != .onIPhone {
                        ShowOnLockScreenButton(enabled: attributes != nil && isLive, sessionIsActive: sessionIsActive)
                            .transition(.opacity)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 32)
            .animation(.smooth(duration: 0.45), value: nowPlayingMode)
        }
        // The song’s artwork, blurred, behind
        // Home, as Apple Music's player does, with a dark band at the top
        // behind the title and the Mac's card.
        .background {
            HomeBackground(artwork: showsArtworkBackground ? model.artwork : nil, style: HomeBackground.style, muted: backgroundMuted)
                .animation(.easeInOut(duration: 0.8), value: backgroundMuted)
                .modifier(HandoffBackgroundRipple())
        }
        .environment(\.colorScheme, showsArtworkBackground && model.artwork != nil && HomeBackground.style != .none ? .dark : colorScheme)
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationTitle("Second Chair")
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
            // A change counts once it has held for two seconds, so Apple
            // Music settling during a hand-over doesn't flicker the buttons
            // (23 November 2026). A hand-over on Home sets it straight away.
            var lastRead: PhoneNowPlaying?
            var steadyReads = 0
            while !Task.isCancelled {
                let fresh = phoneMusic.nowPlaying()
                steadyReads = Self.sameMusic(fresh, lastRead) ? steadyReads + 1 : 0
                lastRead = fresh
                if tick == 0 || steadyReads >= 2 || Self.sameMusic(fresh, phoneNowPlaying) { phoneNowPlaying = fresh }
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

    /// Same song, same playing or paused: only the position differs.
    private static func sameMusic(_ a: PhoneNowPlaying?, _ b: PhoneNowPlaying?) -> Bool {
        a?.isPlaying == b?.isPlaying && a?.catalogID == b?.catalogID && a?.title == b?.title
    }

    /// The artwork goes behind Home whenever there's a song, greyed (below)
    /// when it isn't what's playing.
    private var showsArtworkBackground: Bool {
        guard attributes?.track != nil else { return false }
        switch nowPlayingMode {
        case .live: return true
        case .onIPhone, .iPhonePlaysOther, .lastKnown: return HomeBackground.mutedStyle != .hide
        }
    }

    /// While the phone has the music, or the Mac can't be reached, the Mac's
    /// song is greyed out, and so is its background.
    private var backgroundMuted: Bool {
        switch nowPlayingMode {
        case .onIPhone, .iPhonePlaysOther, .lastKnown: true
        case .live: false
        }
    }

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
            Button("Stop Showing", systemImage: "eye.slash", role: .destructive) {
                Task { await model.stopNowPlaying() }
            }
            .disabled(!sessionIsActive)
        } label: {
            // "Refresh" once the app has a session: it may be showing already,
            // and asking again is how a hidden player comes back.
            Label(sessionIsActive ? "Refresh Lock Screen" : "Show on Lock Screen",
                  systemImage: sessionIsActive ? "arrow.clockwise" : "lock.iphone")
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

/// Home's background: the song's artwork blurred, or its colour, with a dark
/// band at the top. Nothing when there's no artwork.
struct HomeBackground: View {
    enum Style: String { case artwork, colour, none }

    let artwork: CGImage?
    let style: Style
    /// Greyed and darker, as the artwork is while the iPhone has the music.
    var muted = false

    enum MutedStyle: String { case grey, hide }
    /// `-homeBackgroundMuted grey|hide` in development builds; grey by default.
    static var mutedStyle: MutedStyle {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let at = arguments.firstIndex(of: "-homeBackgroundMuted"), arguments.count > at + 1,
           let style = MutedStyle(rawValue: arguments[at + 1]) { return style }
        #endif
        return .grey
    }

    /// `-homeBackground artwork|colour|none` in development builds; artwork by default.
    static var style: Style {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let at = arguments.firstIndex(of: "-homeBackground"), arguments.count > at + 1,
           let style = Style(rawValue: arguments[at + 1]) { return style }
        #endif
        return .artwork
    }

    var body: some View {
        if let artwork, style != .none {
            ZStack {
                switch style {
                case .artwork:
                    Image(decorative: artwork, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .blur(radius: 70, opaque: true)
                        .saturation(muted ? 0 : 1.25)
                        // Pale covers stay readable under white text.
                        .brightness(-0.12)
                        .overlay(Color.black.opacity(muted ? 0.5 : 0.35))
                case .colour:
                    let wall = ArtworkColours.wall(for: artwork)
                    LinearGradient(colors: [wall.top, wall.bottom], startPoint: .top, endPoint: .bottom)
                case .none:
                    EmptyView()
                }
                // Dark behind the title and the Mac's card, fading out by the song.
                LinearGradient(stops: [.init(color: .black.opacity(0.85), location: 0),
                                       .init(color: .black.opacity(0.55), location: 0.18),
                                       .init(color: .clear, location: 0.42)],
                               startPoint: .top, endPoint: .bottom)
            }
            .ignoresSafeArea()
            .transition(.opacity)
            .animation(.smooth(duration: 0.6), value: ObjectIdentifier(artwork))
            .animation(.smooth(duration: 0.6), value: muted)
        } else {
            Color(.systemBackground).ignoresSafeArea()
        }
    }
}
