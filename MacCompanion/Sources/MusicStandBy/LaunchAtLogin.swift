import Observation
import ServiceManagement

/// Launch at Login through `SMAppService.mainApp`. macOS may ask the user to
/// approve it in System Settings › General › Login Items.
@MainActor
@Observable
final class LaunchAtLogin {
    private(set) var isEnabled = false
    private(set) var message: String?

    init() {
        refresh()
    }

    func refresh() {
        switch SMAppService.mainApp.status {
        case .enabled:
            isEnabled = true
            message = nil
        case .requiresApproval:
            isEnabled = true
            message = "Approve Music StandBy in System Settings › General › Login Items."
        case .notRegistered:
            isEnabled = false
            message = nil
        case .notFound:
            isEnabled = false
            message = "Not available for this copy of the app. Move it to Applications first."
        @unknown default:
            isEnabled = false
            message = nil
        }
    }

    func set(_ enabled: Bool) {
        var failure: String?
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            failure = error.localizedDescription
        }
        refresh()
        if let failure { message = failure }
    }
}
