import AppIntents
import CompanionCore

/// Continue from iPhone as a Shortcuts action on the Mac: the menu's button,
/// waiting for the answer (docs/relay/API-v1.md §14). The app is a menu bar
/// app that runs from login; one launched for the action first waits for the
/// relay. Its metadata comes from appintentsmetadataprocessor in
/// scripts/build.sh, since the app isn't built by Xcode.
///
/// App Store Connect refuses Apple product names in intent descriptions
/// (ITMS-90626, seen on the iPhone app), so this one avoids them too.
struct ContinueFromPhoneIntent: AppIntent {
    static let title: LocalizedStringResource = "Continue from iPhone"
    static let description: IntentDescription? = IntentDescription("Brings the music playing on your phone to this computer, from the same point, and pauses it on the phone. The phone has to be playing a song from this computer’s queue, as it is after continuing on the phone.")

    @Dependency private var companion: Companion

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // Launched for this action: the relay connection takes a moment.
        for _ in 0..<50 where companion.connection.phase != .connected {
            try await Task.sleep(for: .milliseconds(100))
        }
        companion.continueFromPhone()
        guard let id = companion.handBack?.id else { return .result(dialog: "Continuing here.") }
        // The companion gives up after its own timeout, so this ends.
        while let progress = companion.handBack, progress.id == id, !progress.isFinished {
            try await Task.sleep(for: .milliseconds(200))
        }
        // Gone means Music plays here now (or a newer request took over).
        guard let progress = companion.handBack, progress.id == id, progress.status != .done else {
            return .result(dialog: "Continuing here.")
        }
        throw ContinueFromPhoneError(message: progress.message ?? "Couldn’t continue here. Try again.")
    }
}

struct ContinueFromPhoneError: Error, CustomLocalizedStringResourceConvertible {
    let message: String
    var localizedStringResource: LocalizedStringResource { "\(message)" }
}

/// Ready-made in the Shortcuts app on the Mac, in Spotlight and for Siri.
struct SecondChairMacShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ContinueFromPhoneIntent(), phrases: [
            "Continue from iPhone with \(.applicationName)",
            "Bring my music back with \(.applicationName)",
        ], shortTitle: "Continue from iPhone", systemImageName: "iphone.and.arrow.forward")
    }
}
