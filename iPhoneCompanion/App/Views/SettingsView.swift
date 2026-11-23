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
    /// The Live Activity card (experiment, 23 November 2026). On unless turned off.
    @AppStorage(LiveActivityController.enabledKey, store: LiveActivityController.defaults) private var showsControls = true

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

    private var lockScreenSection: some View {
        Section {
            // "Refresh" once the app has a session: it may be showing already,
            // and asking again is how a hidden player comes back.
            Button(model.sessionController.isActive ? "Refresh Lock Screen" : "Show on Lock Screen") {
                Task { await model.activateNowPlaying() }
            }
            .disabled(model.attributes == nil)
            Button("Stop Showing", role: .destructive) {
                Task { await model.stopNowPlaying() }
            }
            .disabled(!model.sessionController.isActive)
            // The card and the notification come from the relay, which the demo doesn't use.
            if !isDemoLayout {
                Toggle("Show Controls When Music Starts", isOn: $showsControls)
                    .onChange(of: showsControls) { LiveActivityController.shared.sync() }
                Toggle("Notify When Music Resumes", isOn: Binding(
                    get: { reminders.isEnabled },
                    set: { enabled in Task { await reminders.setEnabled(enabled) } }
                ))
            }
        } header: {
            Text("Lock Screen and StandBy")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                if !isDemoLayout {
                    Text("When your Mac starts playing after a break, its song and controls appear on your Lock Screen and in StandBy, without opening Second Chair.")
                    if showsControls && !LiveActivityController.systemAllows {
                        Text("Live Activities are turned off for Second Chair in Settings.").foregroundStyle(.red)
                    }
                    Text("With controls off, get a notification instead. Tap it to bring Second Chair back to your Lock Screen and StandBy.")
                }
                // iOS shows a session only once the app has asked while open, so a
                // dismissed player stays hidden until the next launch re-requests it.
                Text("If you dismiss the player, it may stay hidden until you next open Second Chair.")
                if let problem = reminders.problem {
                    Text(problem).foregroundStyle(.red)
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
