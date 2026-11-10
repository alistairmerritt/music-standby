import StandByKit
import SwiftUI

@main
struct MusicStandByApp: App {
    @State private var model = AppEnvironment.makeModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.start() }
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
