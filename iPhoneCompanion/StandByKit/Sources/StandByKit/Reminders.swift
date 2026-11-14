import Foundation
import Observation

/// Asks the system to allow notifications. The app target implements it over
/// UserNotifications; tests use a double.
public protocol NotificationPermission: Sendable {
    func request() async -> Bool
}

/// Where the app's ordinary push token goes: the relay, which sends the
/// reminder to it.
public protocol ReminderRelay: Sendable {
    func register(alertToken hex: String) async throws
    func unregister() async throws
}

/// The opt-in "Music playing on <Mac>" reminder.
///
/// iOS shows a remote Now Playing session only once the app has asked for it
/// while open, so a dismissed player stays hidden until the app is opened. The
/// relay can't tell a dismissed player from a showing one, so when the Mac
/// starts playing after a break it sends a notification to a phone that asked.
/// Tapping it opens the app, which brings the player back.
@MainActor
@Observable
public final class ReminderModel {
    public private(set) var isEnabled: Bool
    /// Why reminders aren't working, for the settings footer. Nil when they are.
    public private(set) var problem: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let permission: any NotificationPermission
    @ObservationIgnored private let relay: any ReminderRelay
    @ObservationIgnored private let registerForRemoteNotifications: @MainActor () -> Void
    static let enabledKey = "remindersEnabled"

    public init(
        defaults: UserDefaults,
        permission: any NotificationPermission,
        relay: any ReminderRelay,
        registerForRemoteNotifications: @escaping @MainActor () -> Void
    ) {
        self.defaults = defaults
        self.permission = permission
        self.relay = relay
        self.registerForRemoteNotifications = registerForRemoteNotifications
        isEnabled = defaults.bool(forKey: Self.enabledKey)
    }

    public func setEnabled(_ enabled: Bool) async {
        problem = nil
        if enabled {
            guard await permission.request() else {
                store(false)
                problem = "Notifications are off for Second Chair. Turn them on in Settings to get reminders."
                return
            }
            store(true)
            registerForRemoteNotifications()
        } else {
            store(false)
            do {
                try await relay.unregister()
            } catch {
                problem = "Couldn’t tell the relay to stop reminders: \(error.localizedDescription)"
            }
        }
    }

    /// Asks for the push token again; it can change, and a new pairing needs it.
    public func refresh() {
        if isEnabled { registerForRemoteNotifications() }
    }

    public func didRegister(deviceToken: Data) async {
        guard isEnabled else { return }
        do {
            try await relay.register(alertToken: deviceToken.hexString)
            problem = nil
        } catch {
            problem = "Couldn’t turn on reminders: \(error.localizedDescription)"
        }
    }

    public func didFailToRegister(_ error: any Error) {
        guard isEnabled else { return }
        problem = "Couldn’t turn on reminders: \(error.localizedDescription)"
    }

    private func store(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
    }
}

/// Sends the token to the relay of the current pairing. Without a pairing
/// there's nowhere to send it; `ReminderModel.refresh()` after pairing does.
public struct RelayReminderRelay: ReminderRelay {
    private let client: @Sendable () -> RelayClient?

    public init(client: @escaping @Sendable () -> RelayClient?) {
        self.client = client
    }

    public func register(alertToken hex: String) async throws {
        try await client()?.registerAlertToken(hex)
    }

    public func unregister() async throws {
        try await client()?.removeAlertToken()
    }
}

/// For builds without a relay: reminders have nothing to come from.
public struct NoReminderRelay: ReminderRelay {
    public init() {}
    public func register(alertToken hex: String) async throws {}
    public func unregister() async throws {}
}
