import Foundation
import StandByKit
import UIKit

/// Assembles the app's dependencies.
@MainActor
enum AppEnvironment {
    /// The relay to use. A build gets it from the `MSB_RELAY_HOST` build setting,
    /// which the repository leaves empty; pass it to `xcodebuild` or set it
    /// locally. Without one, Debug builds run on the mock. A Debug launch from
    /// Xcode can point at a development relay with the `MSB_RELAY_URL`
    /// environment variable, such as `http://127.0.0.1:8787`.
    private static var relayConfiguration: RelayConfiguration? {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["MSB_RELAY_URL"], let url = URL(string: raw) {
            return RelayConfiguration(baseURL: url)
        }
        #endif
        if let host = Bundle.main.object(forInfoDictionaryKey: "MSBRelayHost") as? String {
            return RelayConfiguration(host: host)
        }
        return nil
    }

    static func makeModel() -> AppModel {
        #if DEBUG
        if let preview = OnboardingPreview.fromLaunchArguments() { return preview.makeModel() }
        if ScreenshotMode.isOn { return ScreenshotMode.makeModel() }
        #endif
        let container = SharedContainer.appGroup()
        let defaults = UserDefaults(suiteName: AppGroup.identifier) ?? .standard
        let inDemo = DemoMode.resumes(defaults)
        let transport: any PlaybackTransport
        let registrar: any PushTokenRegistrar
        if let relayConfiguration {
            let credentials = KeychainCredentialStore()
            // Keep the remembered Mac in step with the relay credential: a Mac
            // left over from the development mock has none, so pair again.
            // The demo's Mac has none either, and stays.
            let pairing = PairingStore(defaults: defaults)
            switch Result(catching: { try credentials.load() }) {
            case .success(nil) where !inDemo:
                pairing.pairedMac = nil
            case .success(let credential?) where pairing.pairedMac == nil:
                // The Keychain outlives a deleted app; its settings don't.
                pairing.pairedMac = credential.mac
            default:
                break
            }
            let http = URLSessionHTTP()
            let device = currentDevice(defaults: defaults)
            transport = RelayTransport(configuration: relayConfiguration, credentials: credentials, http: http, device: { device })
            registrar = RelayPushTokenRegistrar(container: container) {
                (try? credentials.load()).flatMap { $0 }.map { RelayClient(credential: $0, http: http) }
            }
        } else {
            #if DEBUG
            transport = MockTransport()
            #else
            transport = UnconfiguredTransport()
            #endif
            registrar = MockPushTokenRegistrar(container: container)
        }
        return AppModel(
            // Any build can run the demo, for App Review.
            transport: DemoCapableTransport(real: transport, startsInDemo: inDemo),
            sessionController: RemoteSessionController(),
            container: container,
            defaults: defaults,
            registrar: registrar
        )
    }

    /// Where the first run keeps its progress: the App Group, or, in
    /// development builds' previews and screenshots, their own suites.
    static func onboardingDefaults() -> UserDefaults {
        #if DEBUG
        if OnboardingPreview.fromLaunchArguments() != nil { return UserDefaults(suiteName: OnboardingPreview.suite) ?? .standard }
        if ScreenshotMode.isOn { return UserDefaults(suiteName: ScreenshotMode.suite) ?? .standard }
        #endif
        return UserDefaults(suiteName: AppGroup.identifier) ?? .standard
    }

    /// The opt-in reminder. Its token goes to the current pairing's relay.
    static func makeReminders() -> ReminderModel {
        let defaults = UserDefaults(suiteName: AppGroup.identifier) ?? .standard
        let relay: any ReminderRelay
        if relayConfiguration != nil {
            let credentials = KeychainCredentialStore()
            let http = URLSessionHTTP()
            relay = RelayReminderRelay {
                (try? credentials.load()).flatMap { $0 }.map { RelayClient(credential: $0, http: http) }
            }
        } else {
            relay = NoReminderRelay()
        }
        return ReminderModel(defaults: defaults, permission: SystemNotificationPermission(), relay: relay) {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    /// Continue from iPhone, asked for at the Mac: straight to the relay with
    /// the pairing's credential, like the Shortcuts actions.
    static func makeHandBack() -> HandBackResponder {
        let defaults = UserDefaults(suiteName: AppGroup.identifier) ?? .standard
        let configured = relayConfiguration != nil
        return HandBackResponder(defaults: defaults, makeRemote: {
            guard configured else { throw TransportError.notPaired }
            return try MacRemote.paired(credentials: KeychainCredentialStore())
        }, report: { report in
            try await pairedClient()?.reportHandBack(report)
        })
    }

    /// The app's device token, for Continue from iPhone, whatever the
    /// reminder setting. Without a pairing there's nowhere to send it; the
    /// next launch, or pairing, registers again.
    static func uploadDeviceToken(_ token: Data) async {
        try? await pairedClient()?.registerDeviceToken(token.hexString)
    }

    private static func pairedClient() -> RelayClient? {
        guard relayConfiguration != nil, let credential = (try? KeychainCredentialStore().load()).flatMap({ $0 }) else { return nil }
        return RelayClient(credential: credential, http: URLSessionHTTP(reuseConnections: false))
    }

    /// A random identifier kept for the life of the install. Never hardware-derived.
    private static func currentDevice(defaults: UserDefaults) -> DeviceIdentity {
        let key = "deviceIdentifier"
        let id = defaults.string(forKey: key) ?? UUID().uuidString
        defaults.set(id, forKey: key)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return DeviceIdentity(id: id, name: UIDevice.current.name, kind: .iPhone, appVersion: version, osVersion: UIDevice.current.systemVersion)
    }
}
