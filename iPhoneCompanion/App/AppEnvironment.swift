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
        let container = SharedContainer.appGroup()
        let defaults = UserDefaults(suiteName: AppGroup.identifier) ?? .standard
        let transport: any PlaybackTransport
        let registrar: any PushTokenRegistrar
        if let relayConfiguration {
            let credentials = KeychainCredentialStore()
            // Keep the remembered Mac in step with the relay credential: a Mac
            // left over from the development mock has none, so pair again.
            let pairing = PairingStore(defaults: defaults)
            switch Result(catching: { try credentials.load() }) {
            case .success(nil):
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
            transport: transport,
            sessionController: RemoteSessionController(),
            container: container,
            defaults: defaults,
            registrar: registrar
        )
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
