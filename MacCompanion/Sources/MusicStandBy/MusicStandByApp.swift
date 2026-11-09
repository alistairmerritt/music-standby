import AppKit
import CompanionCore
import SwiftUI

@main
struct MusicStandByApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var companion: Companion
    @State private var launchAtLogin = LaunchAtLogin()

    init() {
        let companion = Companion.live()
        companion.start()
        AppDelegate.companion = companion
        _companion = State(initialValue: companion)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(companion: companion, launchAtLogin: launchAtLogin)
        } label: {
            Image(systemName: companion.snapshot?.state == .automationDenied ? "exclamationmark.triangle" : "music.note")
                .accessibilityLabel("Music StandBy")
        }
        .menuBarExtraStyle(.window)
    }
}

/// Holds termination until the companion has said goodbye to the relay, so a
/// deliberate quit isn't mistaken for a dropped connection.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var companion: Companion?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let companion = Self.companion else { return .terminateNow }
        Task {
            await companion.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
