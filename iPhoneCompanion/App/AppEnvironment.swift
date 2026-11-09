import Foundation
import StandByKit

/// Assembles the app's dependencies.
@MainActor
enum AppEnvironment {
    static func makeModel() -> AppModel {
        let container = SharedContainer.appGroup()
        return AppModel(
            transport: MockTransport(),
            sessionController: RemoteSessionController(),
            container: container,
            defaults: UserDefaults(suiteName: AppGroup.identifier) ?? .standard,
            registrar: MockPushTokenRegistrar(container: container)
        )
    }
}
