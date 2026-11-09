import Foundation
import StandByKit
import UIKit

/// Assembles the app's dependencies.
@MainActor
enum AppEnvironment {
    /// The relay to use. None exists yet, so Debug builds run on the mock.
    /// A Debug launch can point at a development relay with `MSB_RELAY_URL`.
    private static var relayConfiguration: RelayConfiguration? {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["MSB_RELAY_URL"], let url = URL(string: raw) {
            return RelayConfiguration(baseURL: url)
        }
        #endif
        return nil
    }

    static func makeModel() -> AppModel {
        let container = SharedContainer.appGroup()
        let defaults = UserDefaults(suiteName: AppGroup.identifier) ?? .standard
        let transport: any PlaybackTransport
        let registrar: any PushTokenRegistrar
        if let relayConfiguration {
            let credentials = KeychainCredentialStore()
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
        return DeviceIdentity(id: id, name: UIDevice.current.name, kind: .iPhone, osVersion: UIDevice.current.systemVersion)
    }
}
