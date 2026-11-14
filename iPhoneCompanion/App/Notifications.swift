import AppIntents
import StandByKit
import UIKit
import UserNotifications

/// The UIKit side of the reminder and of Continue from iPhone: the push
/// token, how a notification is shown, what its tap does, and the background
/// push that wakes the app. Owns the models, because these arrive here.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = AppEnvironment.makeModel()
    let reminders = AppEnvironment.makeReminders()
    let handBack = AppEnvironment.makeHandBack()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([Self.handBackCategory])
        // Show in Now Playing and Stop Showing act on the app's own model.
        AppDependencyManager.shared.add(dependency: self.model)
        // Every launch: the device token goes to the relay for Continue from
        // iPhone whatever the reminder setting, and it can change.
        application.registerForRemoteNotifications()
        reminders.refresh()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { await AppEnvironment.uploadDeviceToken(deviceToken) }
        Task { await reminders.didRegister(deviceToken: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        reminders.didFailToRegister(error)
    }

    /// Continue from iPhone's background push: hand the music back to the
    /// Mac without showing anything. iOS gives about 30 s, and the hand-back
    /// takes a few at most.
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard let request = HandBackResponder.request(from: userInfo) else { return .noData }
        let status = await handBack.respond(to: request, via: .wake, player: SystemMusicPhonePlayer())
        // Done before the notification came: it has nothing left to ask.
        if status != nil { await Self.removeHandBackNotifications() }
        return status == nil ? .noData : .newData
    }

    /// With the app open, the player is already being brought back. Continue
    /// from iPhone's notification still shows, since only its tap acts.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        notification.request.content.threadIdentifier == HandBackRequest.threadID ? [.banner, .list] : []
    }

    /// "Tap to show on your Lock Screen": showing goes back on, even after
    /// Stop Showing, and the open app asks iOS to show the player.
    /// "Continue on <Mac>?": the tap, which opens the app, or the Continue on
    /// Mac button, which doesn't, is the request.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let content = response.notification.request.content
        switch content.threadIdentifier {
        case Self.reminderThread:
            await model.activateNowPlaying()
        case HandBackRequest.threadID:
            guard [UNNotificationDefaultActionIdentifier, Self.continueOnMacAction].contains(response.actionIdentifier),
                  let request = HandBackResponder.request(from: content.userInfo) else { return }
            await handBack.respond(to: request, via: .tap, player: SystemMusicPhonePlayer())
        default:
            break
        }
    }

    private static func removeHandBackNotifications() async {
        let center = UNUserNotificationCenter.current()
        let ids = await center.deliveredNotifications()
            .filter { $0.request.content.threadIdentifier == HandBackRequest.threadID }
            .map(\.request.identifier)
        if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
    }

    /// Matches the relay's reminder (`REMINDER_ID` in Relay/src/push.ts).
    nonisolated static let reminderThread = "mac-playing"

    /// Continue from iPhone's notification gets a Continue on Mac button that
    /// hands back in the background, without opening the app or unlocking
    /// the phone (the relay credentials are readable after first unlock).
    /// Apple Watch shows the button too, and that's where the notification
    /// goes when the phone is in StandBy, which is locked, and a watch is
    /// worn (13 Nov 2026).
    nonisolated static let continueOnMacAction = "continue-on-mac"

    static var handBackCategory: UNNotificationCategory {
        UNNotificationCategory(
            identifier: HandBackRequest.categoryID,
            actions: [UNNotificationAction(
                identifier: continueOnMacAction, title: "Continue on Mac", options: [],
                icon: UNNotificationActionIcon(systemImageName: "laptopcomputer")
            )],
            intentIdentifiers: []
        )
    }
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
