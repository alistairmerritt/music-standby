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

    /// The hand-over's own limit, in seconds, after reading the relay (at most
    /// 10 s). Shortcuts gives an action about half a minute; Apple doesn't say.
    static let timeLimit: TimeInterval = 15

    /// Each step to the device log, as in the car there's nothing else to read.
    @MainActor static func log(_ text: String) { shortcutLog.log("\(text, privacy: .public)") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let canOpen = systemContext.currentMode.canContinueInForeground
        // The Apple Music permission prompt can't appear in the background.
        if MPMediaLibrary.authorizationStatus() == .notDetermined, canOpen {
            try await continueInForeground("Second Chair needs to ask for access to Apple Music first.", alwaysConfirm: false)
        }
        let player = SystemMusicPhonePlayer()
        // Whether the Mac was connected when the action read its state. An
        // offline Mac can leave no song to continue, which is not the song's
        // fault (20 November 2026, a CarPlay automation with the Mac asleep).
        var macConnected = true
        var title: String?
        // Within Shortcuts' time: before 25 November 2026 a run in the car took
        // 18 minutes and Shortcuts said "an unknown error occurred".
        var outcome = try await ShortcutRemote.run { remote in
            let state = try await remote.read()
            macConnected = state.macConnected
            title = state.playback?.track?.title
            return await remote.handover(record: Self.log)
                .continueOnPhone(with: player, timeout: canOpen ? 6 : 10, within: Self.timeLimit, from: .shortcuts)
        }
        if outcome == .didNotStart, canOpen {
            try await continueInForeground("Open Second Chair to start the song on your iPhone?", alwaysConfirm: false)
            outcome = try await ShortcutRemote.run { remote in
                try await remote.read()
                return await remote.handover(record: Self.log).continueOnPhone(with: player, within: Self.timeLimit, from: .shortcuts)
            }
        }
        let dialog: IntentDialog
        switch outcome {
        case .continued: dialog = "Continuing on your iPhone."
        case .macStillPlaying: dialog = "Playing on your iPhone, but your Mac didn’t pause."
        // Nothing new on the Mac since the last time, as on the next drive
        // with a CarPlay automation: carry on with what the phone has.
        case .resumedHere: dialog = "Continuing where your iPhone left off."
        case .alreadyPlayingHere: dialog = "Already playing on your iPhone."
        case .continuedWithoutMac(let away): dialog = IntentDialog(stringLiteral: ContinueOutcome.withoutMacMessage(away, title: title))
        case .unavailable where !macConnected: throw ShortcutError(ShortcutError.notConnected)
        case .unavailable: throw ShortcutError("Nothing on your Mac can be continued here. The song has to be in Apple Music.")
        case .notAllowed: throw ShortcutError("Allow access to Apple Music in Settings to continue listening on your iPhone.")
        case .didNotStart: throw ShortcutError(ContinueOutcome.didNotStartMessage(here: player.nowPlaying()))
        }
        guard opensMusic else { return .result(dialog: dialog) }
        return .result(opensIntent: OpenURLIntent(SystemMusicPhonePlayer.appURL), dialog: dialog)
    }
}

/// Continue on Mac as an action: the song playing in Apple Music here, on
/// the Mac from the same point, when it's in the Mac's queue.
struct ContinueOnMacIntent: AppIntent {
    static let title: LocalizedStringResource = "Continue on Mac"
    static let description: IntentDescription? = IntentDescription("Plays the song from this phone on your computer from the same point, then pauses Music here. A song your computer’s queue doesn’t have plays there as its station, from the same point when the station starts with it. When a playlist or album isn’t in your library, automated handoffs use the song’s station unless you’ve chosen Add to Library in Settings.")
    static let supportedModes: IntentModes = .background

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let player = SystemMusicPhonePlayer()
        let outcome = try await ShortcutRemote.run { remote in
            try await remote.read()
            let handover = remote.handover()
            let outcome = await handover.sendBackToMac(with: player, from: .shortcuts)
            return (outcome: outcome, keptOut: handover.playedStationInsteadOfAdding)
        }
        let stillHere = player.nowPlaying()?.isPlaying == true ? " Music is still playing on your iPhone." : ""
        // Set to Ask Every Time, an action can't ask, so a playlist or album
        // outside the library went as its song's station: say why, once, in
        // the action's own answer rather than a notification (28 November 2026).
        if outcome.outcome == .sentBack || outcome.outcome == .sentAsStation, outcome.keptOut {
            return .result(dialog: "Continuing on your Mac with a station from this song. When a playlist or album isn’t in your library, automated handoffs use the song’s station unless you’ve chosen Add to Library in Settings.")
        }
        switch outcome.outcome {
        case .sentBack: return .result(dialog: "Continuing on your Mac.")
        case .sentAsStation: return .result(dialog: "Continuing on your Mac with a station from this song.")
        case .nothingPlayingHere: throw ShortcutError("Nothing is playing in Apple Music on your iPhone.")
        case .macRefused: throw ShortcutError("Couldn’t start playback on your Mac." + stillHere)
        case .macDidNotStart: throw ShortcutError("Your Mac didn’t respond. Try again." + stillHere)
        // Only where someone is asked, which an action never is.
        case .cancelled, .needsLibraryChoice, .libraryAddFailed: throw ShortcutError("Nothing was moved.")
        }
    }
}
