import AppIntents
import StandByKit

/// The app's "Show in Now Playing". It opens the app, because iOS lets only
/// an app on screen put its player on the Lock Screen and in StandBy.
struct ShowInNowPlayingIntent: AppIntent {
    static let title: LocalizedStringResource = "Show in Now Playing"
    static let description: IntentDescription? = IntentDescription("Opens Second Chair and puts your Mac’s music on the Lock Screen and in StandBy, as the app’s Show in Now Playing does.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @Dependency private var model: AppModel

    @MainActor
    func perform() async throws -> some IntentResult {
        guard model.pairedMac != nil else { throw ShortcutError(TransportError.notPaired) }
        // Turns showing on; once the Mac's state arrives, the player appears.
        await model.activateNowPlaying()
        return .result()
    }
}

/// The app's "Stop Showing", without opening it.
struct StopShowingIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Showing"
    static let description: IntentDescription? = IntentDescription("Takes your Mac’s music off the Lock Screen and StandBy until you show it again. The music on your Mac carries on.")
    static let supportedModes: IntentModes = .background

    @Dependency private var model: AppModel

    @MainActor
    func perform() async throws -> some IntentResult {
        await model.stopNowPlaying()
        return .result()
    }
}
