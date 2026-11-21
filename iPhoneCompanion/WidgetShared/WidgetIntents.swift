import AppIntents
import Foundation

// The actions behind the widget and the controls (22 November 2026). This
// folder is compiled into the app and the widget extension. The two that
// play music are `AudioPlaybackIntent`s, so iOS runs them in the app's own
// process, where the work is done; the app fills in `WidgetActions` at
// launch. The extension only needs the types, to put them on buttons.

/// What the actions do, set by the app. Empty in the widget extension, which
/// never runs them.
@MainActor
final class WidgetActions {
    static let shared = WidgetActions()
    var continueOnIPhone: (() async throws -> Void)?
    var continueOnMac: (() async throws -> Void)?
    var showOnLockScreen: (() async -> Void)?
}

/// A message for Shortcuts, Siri or the system to show when an action fails.
struct WidgetActionError: Error, CustomLocalizedStringResourceConvertible {
    let message: String
    var localizedStringResource: LocalizedStringResource { "\(message)" }
    static let notReady = WidgetActionError(message: "Open Second Chair once, then try again.")
}

/// Continue on iPhone from the widget or a control: in the background, without
/// opening Music.
struct WidgetContinueOnIPhoneIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Continue on iPhone"
    static let description: IntentDescription? = IntentDescription("Plays the song from your computer on this phone, from the same point, and pauses your computer.")
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let action = WidgetActions.shared.continueOnIPhone else { throw WidgetActionError.notReady }
        try await action()
        return .result()
    }
}

/// Continue on Mac from the widget, after Continue on iPhone.
struct WidgetContinueOnMacIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Continue on Mac"
    static let description: IntentDescription? = IntentDescription("Plays the song from this phone on your computer from the same point, then pauses it here.")
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let action = WidgetActions.shared.continueOnMac else { throw WidgetActionError.notReady }
        try await action()
        return .result()
    }
}

/// Show on Lock Screen from a control. It opens the app, because iOS gives
/// the Lock Screen player only to an app on screen (seen on 21 November
/// 2026: from the background it's refused every time).
struct WidgetShowOnLockScreenIntent: AppIntent {
    static let title: LocalizedStringResource = "Show on Lock Screen"
    static let description: IntentDescription? = IntentDescription("Opens Second Chair to put your computer’s music back on the Lock Screen and in StandBy.")
    static let isDiscoverable = false
    static let supportedModes: IntentModes = .foreground(.immediate)

    @MainActor
    func perform() async throws -> some IntentResult {
        await WidgetActions.shared.showOnLockScreen?()
        return .result()
    }
}
