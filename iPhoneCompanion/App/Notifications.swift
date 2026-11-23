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
    /// The first run. A phone paired before it existed counts as done.
    lazy var onboarding = OnboardingCoordinator(
        progress: OnboardingProgress(defaults: AppEnvironment.onboardingDefaults(), alreadyPaired: model.pairedMac != nil && !model.isDemo),
        model: model
    )
    let reminders = AppEnvironment.makeReminders()
    let handBack = AppEnvironment.makeHandBack()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([Self.handBackCategory])
        // Show in Now Playing and Stop Showing act on the app's own model.
        AppDependencyManager.shared.add(dependency: self.model)
        // The widget's and the controls' buttons run in this process.
        WidgetActions.shared.install(model: model)
        // Every launch: the device token goes to the relay for Continue from
        // iPhone whatever the reminder setting, and it can change.
        application.registerForRemoteNotifications()
        reminders.refresh()
        #if DEBUG
        StationProbe.runIfAsked(model: model)
        HandoverProbe.runIfAsked()
        HandoverProbe.runAlbumIfAsked()
        HandoverProbe.runQueueProbesIfAsked()
        HandoverProbe.runHandoverIfAsked(model: model)
        ScreenshotMode.start(model: model)
        #endif
        return true
    }

    #if DEBUG
    /// Screenshots are portrait, whichever way the phone lies.
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        ScreenshotMode.isOn ? .portrait : .allButUpsideDown
    }
    #endif

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
        // The reminder wakes the app too, which
        // shows the player now rather than at a tap.
        if ReminderPush.isReminder(userInfo) {
            LockScreenRecord.add("Reminder woke the app in the background (app \(application.applicationState == .active ? "on screen" : "not on screen"))")
            // Stop Showing holds until you act: a tap on the reminder, Show on
            // Lock Screen, or Show in Now Playing (23 November 2026). Waking
            // used to turn showing back on by itself.
            guard model.isNowPlayingEnabled else {
                LockScreenRecord.add("…showing is off, so the wake left the player off")
                return .noData
            }
            let shown = await model.activateNowPlaying(waitingForTheMacFor: .seconds(10))
            LockScreenRecord.add("…the wake \(shown ? "had the Mac’s song" : "got no song from the Mac in 10 s")"
                                 + "; iOS \(model.primaryWasRefused ? "refused the player (\(model.sessionController.lastPrimaryError ?? "?"))" : "took the request"))")
            return shown ? .newData : .noData
        }
        guard let request = HandBackResponder.request(from: userInfo) else { return .noData }
        let status = await handBack.respond(to: request, via: .wake, player: SystemMusicPhonePlayer())
        // Done before the notification came: it has nothing left to ask.
        if status != nil { await Self.removeHandBackNotifications() }
        return status == nil ? .noData : .newData
    }

    /// With the app open, the player is already being brought back. Continue
    /// from iPhone's notification still shows, since only its tap acts.
    /// Answered at once, on the thread UIKit asked on.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if notification.request.content.threadIdentifier == Self.reminderThread {
            LockScreenRecord.add("Reminder arrived with Second Chair open; its banner was hidden")
        }
        completionHandler(notification.request.content.threadIdentifier == HandBackRequest.threadID ? [.banner, .list] : [])
    }

    /// "Tap to show on your Lock Screen": showing goes back on, even after
    /// Stop Showing, and the open app asks iOS to show the player.
    /// "Continue on <Mac>?": the tap, which opens the app, or the Continue on
    /// Mac button, which doesn't, is the request.
    ///
    /// The completion handler is called on the main thread, once the work is
    /// done. The async form finished on a background thread, and UIKit then
    /// aborted the app as it updated its snapshot (seen 16 November 2026, a
    /// tap on "Continue on <Mac>?").
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let content = response.notification.request.content
        let thread = content.threadIdentifier
        let acts = [UNNotificationDefaultActionIdentifier, Self.continueOnMacAction].contains(response.actionIdentifier)
        let request = HandBackResponder.request(from: content.userInfo)
        let done = MainThreadCompletion(completionHandler)
        Task { @MainActor in
            switch thread {
            case Self.reminderThread:
                LockScreenRecord.add("Reminder tapped")
                await self.model.activateNowPlaying()
            case HandBackRequest.threadID:
                if acts, let request {
                    await self.handBack.respond(to: request, via: .tap, player: SystemMusicPhonePlayer())
                }
            default:
                break
            }
            done.call()
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

/// A UIKit completion handler, carried to the main actor and called there.
/// UIKit's blocks aren't marked Sendable, though calling one on the main
/// thread is exactly what it wants.
private struct MainThreadCompletion: @unchecked Sendable {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @MainActor func call() { handler() }
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
