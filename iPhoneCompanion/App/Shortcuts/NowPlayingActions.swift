import AppIntents
import StandByKit

/// The app's "Show in Now Playing". It runs in the background, with the phone
/// locked or not, and opens the app (asking to unlock) only when the Mac's
/// state doesn't arrive in time. Until 19 November 2026 it always opened the
/// app, because iOS lets only an app on screen put its player on the Lock
/// Screen; a test on a locked phone showed the player without it.
struct ShowInNowPlayingIntent: AppIntent {
    static let title: LocalizedStringResource = "Show in Now Playing"
    static let description: IntentDescription? = IntentDescription("Puts your computer’s music on the Lock Screen and in StandBy, as the app’s Show in Now Playing does. If your computer’s music can’t be reached in the background, it opens Second Chair.")
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    /// How long to wait for the Mac's state before opening the app.
    static let stateWait: Duration = .seconds(10)

    @Dependency private var model: AppModel

    @MainActor
    func perform() async throws -> some IntentResult {
        guard model.pairedMac != nil else { throw ShortcutError(TransportError.notPaired) }
        let reached = await model.activateNowPlaying(waitingForTheMacFor: Self.stateWait)
        // Shown from the background, unless another player holds the Lock
        // Screen: then iOS refuses the background request (error 5) and only
        // the app on screen can take it back (21 November 2026).
        shortcutLog.notice("Show in Now Playing: reached \(reached, privacy: .public), primary refused \(model.primaryWasRefused, privacy: .public), can open \(systemContext.currentMode.canContinueInForeground, privacy: .public)")
        if reached, !model.primaryWasRefused { return .result() }
        guard systemContext.currentMode.canContinueInForeground else {
            if reached { return .result() }
            throw ShortcutError("Your Mac’s music couldn’t be reached. Check that your Mac is awake and Second Chair is open on it.")
        }
        shortcutLog.notice("Show in Now Playing: reached \(reached, privacy: .public), primary refused \(model.primaryWasRefused, privacy: .public); opening the app")
        do {
            try await continueInForeground("Open Second Chair to show your Mac’s music?", alwaysConfirm: false)
        } catch {
            shortcutLog.error("Show in Now Playing: couldn’t open the app: \(String(describing: error), privacy: .public)")
            throw error
        }
        shortcutLog.notice("Show in Now Playing: in the foreground")
        await model.activateNowPlaying()
        return .result()
    }
}

/// The app's "Stop Showing", without opening it.
struct StopShowingIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Showing"
    static let description: IntentDescription? = IntentDescription("Takes your computer’s music off the Lock Screen and StandBy until you show it again. The music on your computer carries on.")
    static let supportedModes: IntentModes = .background

    @Dependency private var model: AppModel

    @MainActor
    func perform() async throws -> some IntentResult {
        await model.stopNowPlaying()
        return .result()
    }
}
