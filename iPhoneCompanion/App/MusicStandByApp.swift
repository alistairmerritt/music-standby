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
                }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    switch phase {
                    case .active: Task { await model.sceneDidBecomeActive() }
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
            if WidgetPreviewPage.isOn { WidgetPreviewPage() } else { content }
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
                NavigationStack { HomeView() }
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
