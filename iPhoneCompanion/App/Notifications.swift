import StandByKit
import UIKit
import UserNotifications

/// The UIKit side of the reminder: the push token, how a notification is
/// shown, and what its tap does. Owns the models, because these arrive here.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = AppEnvironment.makeModel()
    let reminders = AppEnvironment.makeReminders()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        reminders.refresh()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { await reminders.didRegister(deviceToken: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        reminders.didFailToRegister(error)
    }

    /// With the app open, the player is already being brought back.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        []
    }

    /// "Tap to show on your Lock Screen": showing goes back on, even after
    /// Stop Showing, and the open app asks iOS to show the player.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.notification.request.content.threadIdentifier == Self.reminderThread else { return }
        await model.activateNowPlaying()
    }

    /// Matches the relay's reminder (`REMINDER_ID` in Relay/src/push.ts).
    nonisolated static let reminderThread = "mac-playing"
}

/// Alerts only: the reminder is meant to be seen, not heard.
struct SystemNotificationPermission: NotificationPermission {
    func request() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])) ?? false
    }
}
