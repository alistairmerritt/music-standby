import AppIntents
import AppKit
import CompanionCore
import StandByProtocol
import SwiftUI

@main
struct MusicStandByApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var companion: Companion
    @State private var relay: RelayAccount?
    @State private var musicRemote: MusicRemoteAccount
    @State private var launchAtLogin = LaunchAtLogin()

    init() {
        // The build's own relay (MSBRelayHost in Info.plist), unless `relayURL`
        // in defaults names another; see RelayEndpoint. Neither: the mock.
        let relay = RelayEndpoint.current().map {
            RelayAccount(baseURL: $0, store: KeychainCredentialStore(account: $0.absoluteString))
        }
        let transport: any CompanionTransport = relay.map { RelayTransport(client: $0.client, token: $0.token) } ?? MockRelayTransport()
        let companion = Companion.live(transport: transport)
        if let relay {
            let device = companion.device
            let transport = companion.transport
            Task { await relay.register(device: device) }
            // Unpaired from the phone, or the relay was reset: start over.
            companion.onCredentialsRejected = {
                Task { @MainActor in
                    await relay.reregister(device: device)
                    await transport.connect(hello: Hello(device: device))
                }
            }
        }
        let musicRemote = MusicRemoteAccount()
        // Songs not in the library have no catalogue ID over Music's remote
        // protocol; they're looked up, unless `catalogArtwork` is off.
        let lookup: (any CatalogIDLookup)? = (UserDefaults.standard.object(forKey: "catalogArtwork") as? Bool) == false ? nil : ITunesCatalogIDs()
        let reader = { (client: MusicRemoteClient?) -> (any MusicRemoteReading)? in
            guard let client else { return nil }
            guard let lookup else { return client }
            return CatalogFillingRemote(remote: client, lookup: lookup)
        }
        companion.remote = reader(musicRemote.client)
        musicRemote.onClientChange = { [weak companion] client in companion?.remote = reader(client) }
        companion.start()
        AppDelegate.companion = companion
        // The Continue from iPhone Shortcuts action works on this companion.
        AppDependencyManager.shared.add(dependency: companion)
        _companion = State(initialValue: companion)
        _relay = State(initialValue: relay)
        _musicRemote = State(initialValue: musicRemote)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(companion: companion, relay: relay, musicRemote: musicRemote, launchAtLogin: launchAtLogin)
        } label: {
            Image(systemName: companion.snapshot?.state == .automationDenied ? "exclamationmark.triangle" : "music.note")
                .accessibilityLabel("Second Chair")
        }
        .menuBarExtraStyle(.window)
    }
}

/// Holds termination until the companion has said goodbye to the relay, so a
/// deliberate quit isn't mistaken for a dropped connection.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var companion: Companion?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let companion = Self.companion else { return .terminateNow }
        Task {
            await companion.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
