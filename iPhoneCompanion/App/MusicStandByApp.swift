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
                .environment(appDelegate.reminders)
                .task { await model.start() }
                // A new pairing has a new relay record, without the token.
                .onChange(of: model.pairedMac) { _, mac in
                    if mac != nil { appDelegate.reminders.refresh() }
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

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if !model.hasSeenIntro {
                IntroView()
            } else if model.pairedMac == nil {
                NavigationStack { PairingView() }
            } else {
                NavigationStack { HomeView() }
            }
        }
        .animation(.default, value: model.hasSeenIntro)
        .animation(.default, value: model.pairedMac)
    }
}
