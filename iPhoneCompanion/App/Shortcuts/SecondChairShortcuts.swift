import AppIntents

/// The ready-made shortcuts: in the Shortcuts app under Second Chair, in
/// Spotlight, for the Action button, and for Siri by these phrases, with no
/// setup. iOS allows ten. Jump to Time is an action only, for building your own.
struct SecondChairShortcuts: AppShortcutsProvider {
    static let shortcutTileColor: ShortcutTileColor = .grayBlue

    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PlayPauseOnMacIntent(), phrases: [
            "Play or pause \(.applicationName)",
            "Toggle \(.applicationName)",
        ], shortTitle: "Play or Pause", systemImageName: "playpause.fill")
        AppShortcut(intent: PauseOnMacIntent(), phrases: [
            "Pause \(.applicationName)",
            "Pause my Mac with \(.applicationName)",
        ], shortTitle: "Pause", systemImageName: "pause.fill")
        AppShortcut(intent: PlayOnMacIntent(), phrases: [
            "Resume \(.applicationName)",
            "Play my Mac with \(.applicationName)",
        ], shortTitle: "Play", systemImageName: "play.fill")
        AppShortcut(intent: NextSongOnMacIntent(), phrases: [
            "Next song in \(.applicationName)",
            "Skip in \(.applicationName)",
        ], shortTitle: "Next Song", systemImageName: "forward.fill")
        AppShortcut(intent: PreviousSongOnMacIntent(), phrases: [
            "Previous song in \(.applicationName)",
            "Go back in \(.applicationName)",
        ], shortTitle: "Previous Song", systemImageName: "backward.fill")
        AppShortcut(intent: SetVolumeOnMacIntent(), phrases: [
            "Set the volume in \(.applicationName)",
            "Change the volume in \(.applicationName)",
        ], shortTitle: "Set Volume", systemImageName: "speaker.wave.2.fill")
        AppShortcut(intent: ContinueOnIPhoneIntent(), phrases: [
            "Continue on iPhone with \(.applicationName)",
            "Move the music to my iPhone with \(.applicationName)",
        ], shortTitle: "Continue on iPhone", systemImageName: "iphone")
        AppShortcut(intent: ContinueOnMacIntent(), phrases: [
            "Continue on Mac with \(.applicationName)",
            "Move the music to my Mac with \(.applicationName)",
        ], shortTitle: "Continue on Mac", systemImageName: "laptopcomputer")
        AppShortcut(intent: ShowInNowPlayingIntent(), phrases: [
            "Show \(.applicationName) on the Lock Screen",
            "Show \(.applicationName) in Now Playing",
        ], shortTitle: "Show in Now Playing", systemImageName: "rectangle.on.rectangle")
        AppShortcut(intent: StopShowingIntent(), phrases: [
            "Stop showing \(.applicationName)",
            "Hide \(.applicationName) from the Lock Screen",
        ], shortTitle: "Stop Showing", systemImageName: "eye.slash")
    }
}
