import AppIntents
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
        // Show in Now Playing and Stop Showing act on the app's own model.
        AppDependencyManager.shared.add(dependency: self.model)
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

/// Alerts only: the reminder is meant to be seen, not heard. It arrives as
/// Time Sensitive (the relay sets `interruption-level`, and the app has the
/// entitlement), so a Focus or a scheduled Summary doesn't hold it back.
/// That's not an authorisation option: the person controls it per app and
/// per Focus in Settings.
struct SystemNotificationPermission: NotificationPermission {
    func request() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])) ?? false
    }
}
