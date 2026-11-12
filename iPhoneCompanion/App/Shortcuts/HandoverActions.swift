import AppIntents
import MediaPlayer
import StandByKit

/// Continue on iPhone as an action, the same steps as the app's button.
/// It tries without opening the app. If Apple Music here won't start that
/// way, it asks to open the app and tries again: whether a background action
/// may start Apple Music hasn't been seen on an iPhone yet.
struct ContinueOnIPhoneIntent: AppIntent {
    static let title: LocalizedStringResource = "Continue on iPhone"
    static let description: IntentDescription? = IntentDescription("Plays the song from your Mac on this iPhone, from the same point and with your Up Next queue, then pauses your Mac. Your Mac keeps playing if the song can’t start here.")
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

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
        switch outcome {
        case .continued: return .result(dialog: "Continuing on your iPhone.")
        case .macStillPlaying: return .result(dialog: "Playing on your iPhone, but your Mac didn’t pause.")
        case .unavailable: throw ShortcutError("Nothing on your Mac can be continued here. The song has to be in Apple Music.")
        case .notAllowed: throw ShortcutError("Allow access to Apple Music in Settings to continue listening on your iPhone.")
        case .didNotStart: throw ShortcutError("Couldn’t start playback on your iPhone. Music is still playing on your Mac.")
        }
    }
}

/// Continue on Mac as an action: the song playing in Apple Music here, on
/// the Mac from the same point, when it's in the Mac's queue.
struct ContinueOnMacIntent: AppIntent {
    static let title: LocalizedStringResource = "Continue on Mac"
    static let description: IntentDescription? = IntentDescription("Plays the song from this iPhone on your Mac from the same point, then pauses Apple Music here. The song has to be in your Mac’s queue, as it is after Continue on iPhone.")
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
