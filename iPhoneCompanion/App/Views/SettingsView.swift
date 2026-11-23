import StandByKit
import SwiftUI
import UIKit

/// Everything Home doesn't need every time: the Lock Screen player and its
/// notification, Continue Listening's status and preference, the Mac, the
/// Shortcuts guide and Diagnostics (21 November 2026 redesign).
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(ReminderModel.self) private var reminders
    @Environment(OnboardingCoordinator.self) private var onboarding
    @Environment(\.openURL) private var openURL
    @State private var isConfirmingUnpair = false
    @State private var phoneMusic = SystemMusicPhonePlayer()
    @State private var appleMusicAccess: AppleMusicAccess = .allowed
    @State private var canPlayCatalog: Bool?
    /// Off unless turned on (17 November 2026), as adding changes the
    /// library: the Mac can only play a playlist or album that's in it.
    @AppStorage(HandoverMemory.addsToLibraryKey, store: UserDefaults(suiteName: AppGroup.identifier)) private var addsToLibrary = false
    /// Player Display (24 November 2026), kept by `LiveActivityController.setDisplay`.
    @AppStorage(PlayerDisplay.key, store: LiveActivityController.defaults) private var displayRaw = ""
    private var display: PlayerDisplay { PlayerDisplay(rawValue: displayRaw) ?? LiveActivityController.display }

    var body: some View {
        Form {
            Section {
                ConnectionCard(macName: model.pairedMac?.name ?? "Your Mac", connection: model.connection, isDemo: isDemoLayout) {
                    Task { await model.reconnect() }
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
            lockScreenSection
            if !isDemoLayout { continueListeningSection }
            macSection
            shortcutsSection
            helpSection
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Unpair this Mac?", isPresented: $isConfirmingUnpair, titleVisibility: .visible) {
            Button("Unpair", role: .destructive) {
                Task { await model.unpair() }
            }
        } message: {
            Text("You’ll need a new pairing code to connect again.")
        }
        .task {
            appleMusicAccess = phoneMusic.access
            canPlayCatalog = await phoneMusic.canPlayCatalog()
        }
    }

    /// The player's buttons and Player Display, then the notification, so
    /// each explanation sits under what it explains (24 November 2026).
    @ViewBuilder private var lockScreenSection: some View {
        // The demo doesn't use the relay, so it has Now Playing alone.
        let display = isDemoLayout ? .nowPlaying : display
        Section {
            if display == .liveActivity {
                Button("Show Live Activity") {
                    Task {
                        await model.activateNowPlaying()   // showing on; Now Playing isn't asked for
                        await LiveActivityController.shared.showCard(fresh: true)
                    }
                }
                .disabled(model.attributes == nil)
            } else {
                // "Restore" once the app has a session: it may be showing already,
                // and asking again is how a hidden player comes back.
                Button(model.sessionController.isActive ? "Restore Now Playing" : "Show on Lock Screen") {
                    Task { await model.activateNowPlaying() }
                }
                .disabled(model.attributes == nil)
            }
            Button("Stop Showing", role: .destructive) {
                Task { await model.stopNowPlaying() }
            }
            .disabled(display == .liveActivity ? !model.isNowPlayingEnabled : !model.sessionController.isActive)
            if !isDemoLayout {
                NavigationLink {
                    PlayerDisplayPage()
                } label: {
                    LabeledContent("Player Display", value: display.title)
                }
            }
        } header: {
            Text("Lock Screen and StandBy")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                if display == .liveActivity {
                    Text("If you swipe the Live Activity away, open Second Chair to show it again.")
                } else {
                    // iOS shows a session only once the app has asked while open, so a
                    // dismissed player stays hidden until the next launch re-requests it.
                    Text("If you dismiss the player, it may stay hidden until you next open Second Chair.")
                }
                if display.usesLiveActivity && !LiveActivityController.systemAllows {
                    Text("Live Activities are turned off for Second Chair in Settings.").foregroundStyle(.red)
                }
            }
        }
        // The notification comes from the relay, which the demo doesn't use.
        if !isDemoLayout {
            Section {
                Toggle("Notify When Music Resumes", isOn: Binding(
                    get: { reminders.isEnabled },
                    set: { enabled in Task { await reminders.setEnabled(enabled) } }
                ))
            } footer: {
                // The relay sends it only when it didn't start the Live Activity.
                VStack(alignment: .leading, spacing: 8) {
                    Text(display.usesLiveActivity
                         ? "If the Live Activity can’t show, get a notification instead when your Mac starts playing after a break. Tap it to open Second Chair."
                         : "Get a notification when your Mac starts playing after a break. Tap it to bring Now Playing back.")
                    if let problem = reminders.problem {
                        Text(problem).foregroundStyle(.red)
                    }
                }
            }
        }
    }

    @ViewBuilder private var continueListeningSection: some View {
        Section {
            if let status = continueListening {
                LabeledContent("Status", value: status.title)
                if status == .setUpOnMac || status == .reconnectOnMac {
                    Button("Set Up Continue Listening") { onboarding.resume(.continueMusic) }
                }
                if case .allowAppleMusic(let canAsk) = status {
                    Button(canAsk ? "Allow Apple Music Access" : "Open Settings") {
                        Task { await allowAppleMusic(canAsk) }
                    }
                }
            }
        } header: {
            Text("Continue Listening")
        } footer: {
            if let detail = continueListening?.detail { Text(detail) }
        }
        // Its own section, so the heading says when it applies: only Continue
        // on Mac, only an Apple Music playlist or album not in the library
        // (21 November 2026; was "Automatically Add to Library").
        Section {
            Toggle("Add Playlists and Albums to Library", isOn: $addsToLibrary)
        } header: {
            Text("When Continuing on Mac")
        } footer: {
            Text("Your Mac can only continue a playlist or album that’s in your library. With this on, Second Chair adds it when needed, and it stays in your library. With this off, your Mac plays the song’s station instead.")
        }
    }

    private var macSection: some View {
        Section("Mac") {
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

    private var shortcutsSection: some View {
        Section {
            Link(destination: URL(string: "https://madewithmerritt.com/second-chair/guide/#shortcuts")!) {
                LabeledContent("Shortcuts and Automation") { Image(systemName: "arrow.up.right").foregroundStyle(.tertiary) }
            }
        } footer: {
            Text("Control your Mac with Siri, or move your music when CarPlay or your headphones connect.")
        }
    }

    private var helpSection: some View {
        Section {
            Link(destination: URL(string: "https://madewithmerritt.com/second-chair/getting-started/")!) {
                LabeledContent("Setup Guide") { Image(systemName: "arrow.up.right").foregroundStyle(.tertiary) }
            }
            NavigationLink("Diagnostics") { DiagnosticsView() }
        } header: {
            Text("Help")
        } footer: {
            Text(versionText)
        }
    }

    /// As on Home: development builds' screenshots show a paired Mac's settings.
    private var isDemoLayout: Bool {
        #if DEBUG
        if ScreenshotMode.isOn { return false }
        #endif
        return model.isDemo
    }

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Second Chair \(version) (\(build))"
    }

    private var continueListening: ContinueListeningStatus? {
        ContinueListeningStatus.assess(mac: model.macMusicConnection, appleMusicAccess: appleMusicAccess, canPlayCatalog: canPlayCatalog)
    }

    /// Asks for Apple Music access, or, once refused, opens Settings.
    private func allowAppleMusic(_ canAsk: Bool) async {
        if canAsk {
            _ = await phoneMusic.requestAccess()
            appleMusicAccess = phoneMusic.access
            canPlayCatalog = await phoneMusic.canPlayCatalog()
        } else if let url = URL(string: UIApplication.openSettingsURLString) {
            openURL(url)
        }
    }
}

/// The Continue Listening status's words (16 November 2026).
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
