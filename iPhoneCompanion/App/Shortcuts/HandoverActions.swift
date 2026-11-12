import AppIntents
import MediaPlayer
import StandByKit

/// Continue on iPhone as an action, the same steps as the app's button,
/// then the Music app, as the button does. It runs without opening Second
/// Chair: on an iPhone on 12 November 2026 Apple Music started from the
/// background. Should that ever fail, it opens Second Chair and tries again.
struct ContinueOnIPhoneIntent: AppIntent {
    static let title: LocalizedStringResource = "Continue on iPhone"
    static let description: IntentDescription? = IntentDescription("Plays the song from your computer on this phone, from the same point and with your Up Next queue, then pauses your computer. Your computer keeps playing if the song can’t start here.")
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    /// On by default, as the app's button opens Music. Off for an automation
    /// that shouldn't bring an app to the screen, such as one in the car.
    @Parameter(title: "Open Music", description: "Show the Music app once the song is playing here.", default: true)
    var opensMusic: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Continue on iPhone") {
            \.$opensMusic
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let canOpen = systemContext.currentMode.canContinueInForeground
        // The Apple Music permission prompt can't appear in the background.
        if MPMediaLibrary.authorizationStatus() == .notDetermined, canOpen {
            try await continueInForeground("Second Chair needs to ask for access to Apple Music first.", alwaysConfirm: false)
        }
        let player = SystemMusicPhonePlayer()
        var outcome = try await ShortcutRemote.run { remote in
            try await remote.read()
            return await remote.handover().continueOnPhone(with: player, timeout: canOpen ? 6 : 10)
        }
        if outcome == .didNotStart, canOpen {
            try await continueInForeground("Open Second Chair to start the song on your iPhone?", alwaysConfirm: false)
            outcome = try await ShortcutRemote.run { remote in
                try await remote.read()
                return await remote.handover().continueOnPhone(with: player)
            }
        }
        let dialog: IntentDialog
        switch outcome {
        case .continued: dialog = "Continuing on your iPhone."
        case .macStillPlaying: dialog = "Playing on your iPhone, but your Mac didn’t pause."
        case .unavailable: throw ShortcutError("Nothing on your Mac can be continued here. The song has to be in Apple Music.")
        case .notAllowed: throw ShortcutError("Allow access to Apple Music in Settings to continue listening on your iPhone.")
        case .didNotStart: throw ShortcutError("Couldn’t start playback on your iPhone. Music is still playing on your Mac.")
        }
        guard opensMusic else { return .result(dialog: dialog) }
        return .result(opensIntent: OpenURLIntent(SystemMusicPhonePlayer.appURL), dialog: dialog)
    }
}

/// Continue on Mac as an action: the song playing in Apple Music here, on
/// the Mac from the same point, when it's in the Mac's queue.
struct ContinueOnMacIntent: AppIntent {
    static let title: LocalizedStringResource = "Continue on Mac"
    static let description: IntentDescription? = IntentDescription("Plays the song from this phone on your computer from the same point, then pauses Music here. The song has to be in your computer’s queue, as it is after continuing on this phone.")
    static let supportedModes: IntentModes = .background

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let player = SystemMusicPhonePlayer()
        let outcome = try await ShortcutRemote.run { remote in
            try await remote.read()
            return await remote.handover().sendBackToMac(with: player)
        }
        let stillHere = player.nowPlaying()?.isPlaying == true ? " Music is still playing on your iPhone." : ""
        switch outcome {
        case .sentBack: return .result(dialog: "Continuing on your Mac.")
        case .nothingPlayingHere: throw ShortcutError("Nothing is playing in Apple Music on your iPhone.")
        case .notInMacQueue: throw ShortcutError("This song isn’t in your Mac’s queue.")
        case .macRefused: throw ShortcutError("Couldn’t start playback on your Mac." + stillHere)
        case .macDidNotStart: throw ShortcutError("Your Mac didn’t respond. Try again." + stillHere)
        }
    }
}
