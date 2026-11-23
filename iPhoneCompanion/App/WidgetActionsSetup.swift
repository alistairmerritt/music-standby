import StandByKit

/// The widget's and controls' actions, done by the app (22 November 2026).
/// The same steps as the Shortcuts actions, in the background, without
/// opening Music. Errors read as the Shortcuts actions' do.
extension WidgetActions {
    func install(model: AppModel) {
        continueOnIPhone = {
            let player = SystemMusicPhonePlayer()
            var macConnected = true
            let outcome = try await ShortcutRemote.run { remote in
                macConnected = try await remote.read().macConnected
                return await remote.handover().continueOnPhone(with: player, from: .widget)
            }
            switch outcome {
            case .continued, .macStillPlaying, .resumedHere, .alreadyPlayingHere: return
            case .unavailable where !macConnected: throw WidgetActionError(message: ShortcutError.notConnected)
            case .unavailable: throw WidgetActionError(message: "Nothing on your Mac can be continued here. The song has to be in Apple Music.")
            case .notAllowed: throw WidgetActionError(message: "Allow access to Apple Music in Settings to continue listening on your iPhone.")
            case .didNotStart: throw WidgetActionError(message: "Couldn’t start playback on your iPhone. Music is still playing on your Mac.")
            }
        }
        continueOnMac = {
            let player = SystemMusicPhonePlayer()
            let outcome = try await ShortcutRemote.run { remote in
                try await remote.read()
                return await remote.handover().sendBackToMac(with: player, from: .widget)
            }
            switch outcome {
            case .sentBack, .sentAsStation: return
            case .nothingPlayingHere: throw WidgetActionError(message: "Nothing is playing in Apple Music on your iPhone.")
            case .macRefused: throw WidgetActionError(message: "Couldn’t start playback on your Mac.")
            case .macDidNotStart: throw WidgetActionError(message: "Your Mac didn’t respond. Try again.")
            }
        }
        // The app is on screen by now: the request for the player is granted.
        showOnLockScreen = { await model.activateNowPlaying() }
    }
}
