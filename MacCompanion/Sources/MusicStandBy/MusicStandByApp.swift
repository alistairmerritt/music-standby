import AppKit
import CompanionCore
import StandByProtocol
import SwiftUI

@main
struct MusicStandByApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var companion: Companion
    @State private var relay: RelayAccount?
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
        companion.start()
        AppDelegate.companion = companion
        _companion = State(initialValue: companion)
        _relay = State(initialValue: relay)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(companion: companion, relay: relay, launchAtLogin: launchAtLogin)
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
