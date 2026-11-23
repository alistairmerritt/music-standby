import StandByKit
import SwiftUI

@main
struct MusicStandByApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    private var model: AppModel { appDelegate.model }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(appDelegate.onboarding)
                .environment(appDelegate.reminders)
                .task { await model.start() }
                // A new pairing has a new relay record, without the tokens.
                .onChange(of: model.pairedMac) { _, mac in
                    guard mac != nil else { return }
                    UIApplication.shared.registerForRemoteNotifications()
                    appDelegate.reminders.refresh()
                    LiveActivityController.shared.uploadStartToken()
                }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    switch phase {
                    case .active: Task {
                        let outcome = await model.sceneDidBecomeActive()
                        let what = switch outcome {
                        case .requested(refused: nil): "asked iOS for the Mac’s player; iOS didn’t refuse"
                        case .requested(refused: let reason?): "asked iOS for the Mac’s player; iOS refused (\(reason))"
                        case .deferredToPhone: "Apple Music here was playing, so nothing was asked"
                        case .notShowing: "showing is off, so nothing was asked"
                        case .nothingToShow: "no song from the Mac yet, so nothing was asked"
                        case .liveActivity: "Player Display is Live Activity, so Now Playing wasn’t asked for"
                        }
                        LockScreenRecord.add("Second Chair came to the front; \(what)")
                        // The Mac's player is back, so the card isn't needed (experiment).
                        if case .requested(refused: nil) = outcome {
                            LiveActivityController.shared.endAll(because: "the app brought the Mac’s player back")
                        }
                        // Live Activity chosen: the card, if none is showing.
                        if outcome == .liveActivity { await LiveActivityController.shared.showCard() }
                    }
                    case .background: Task { await model.sceneDidEnterBackground() }
                    default: break
                    }
                }
        }
    }
}

/// The first run until it's done, then Home. The demo always shows Home.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(OnboardingCoordinator.self) private var onboarding

    var body: some View {
        Group {
            #if DEBUG
            if WidgetPreviewPage.isOn { WidgetPreviewPage() } else if LiveActivityPreviewPage.isOn { LiveActivityPreviewPage() } else { content }
            #else
            content
            #endif
        }
    }

    @ViewBuilder private var content: some View {
        Group {
            if !model.isDemo, onboarding.route != nil || model.pairedMac == nil {
                OnboardingView(flow: onboarding)
            } else {
                // The hand-over's light and ripple cover all of Home, title included.
                NavigationStack { HomeView() }
                    .modifier(HandoffEffect())
            }
        }
        .animation(.smooth, value: onboarding.route == nil)
        .animation(.smooth, value: model.isDemo)
        // Unpaired, or out of the demo: setup again, from wherever fits.
        .onChange(of: model.pairedMac) { old, new in
            if old != nil, new == nil, !model.isDemo { onboarding.restart(model) }
        }
        .onChange(of: model.isDemo) { _, inDemo in
            if !inDemo { onboarding.restart(model) }
        }
    }
}
