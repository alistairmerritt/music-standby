import AppIntents
import StandByKit

// The Mac's controls as Shortcuts actions, one each. They go to the relay
// themselves and never open the app, so they work from Siri, the Action
// button, a widget or an automation while the phone is locked.

struct PlayPauseOnMacIntent: AppIntent {
    static let title: LocalizedStringResource = "Play or Pause on Mac"
    static let description: IntentDescription? = IntentDescription("Pauses Music on your Mac if it’s playing, and plays it if it isn’t.")
    static let supportedModes: IntentModes = .background

    @MainActor
    func perform() async throws -> some IntentResult {
        try await ShortcutRemote.run { try await $0.playOrPause() }
        return .result()
    }
}

struct PlayOnMacIntent: AppIntent {
    static let title: LocalizedStringResource = "Play on Mac"
    static let description: IntentDescription? = IntentDescription("Plays Music on your Mac. Does nothing if it’s already playing.")
    static let supportedModes: IntentModes = .background

    @MainActor
    func perform() async throws -> some IntentResult {
        try await ShortcutRemote.run { try await $0.run(.play) }
        return .result()
    }
}

struct PauseOnMacIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause on Mac"
    static let description: IntentDescription? = IntentDescription("Pauses Music on your Mac. Does nothing if it’s already paused.")
    static let supportedModes: IntentModes = .background

    @MainActor
    func perform() async throws -> some IntentResult {
        try await ShortcutRemote.run { try await $0.run(.pause) }
        return .result()
    }
}

struct NextSongOnMacIntent: AppIntent {
    static let title: LocalizedStringResource = "Next Song on Mac"
    static let description: IntentDescription? = IntentDescription("Skips to the next song in Music on your Mac.")
    static let supportedModes: IntentModes = .background

    @MainActor
    func perform() async throws -> some IntentResult {
        try await ShortcutRemote.run { try await $0.run(.next) }
        return .result()
    }
}

struct PreviousSongOnMacIntent: AppIntent {
    static let title: LocalizedStringResource = "Previous Song on Mac"
    static let description: IntentDescription? = IntentDescription("Goes back to the previous song in Music on your Mac.")
    static let supportedModes: IntentModes = .background

    @MainActor
    func perform() async throws -> some IntentResult {
        try await ShortcutRemote.run { try await $0.run(.previous) }
        return .result()
    }
}

struct JumpToTimeOnMacIntent: AppIntent {
    static let title: LocalizedStringResource = "Jump to Time on Mac"
    static let description: IntentDescription? = IntentDescription("Jumps to a point in the song playing on your Mac, in seconds: 90 is 1:30 in.")
    static let supportedModes: IntentModes = .background

    /// Seconds only. With a unit to choose, the Shortcuts prompt ignored the
    /// default of seconds and took 30 as 30 minutes (iPhone, 12 November 2026).
    @Parameter(title: "Time", unit: .seconds, supportsNegativeNumbers: false)
    var time: Measurement<UnitDuration>

    static var parameterSummary: some ParameterSummary {
        Summary("Jump to \(\.$time) into the Mac’s song")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let seconds = time.converted(to: .seconds).value
        shortcutLog.log("Jump to Time: \(time.value, privacy: .public) \(time.unit.symbol, privacy: .public) = \(seconds, privacy: .public) s")
        try await ShortcutRemote.run { try await $0.seek(to: seconds) }
        return .result()
    }
}

struct SetVolumeOnMacIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Volume on Mac"
    static let description: IntentDescription? = IntentDescription("Sets Music’s own volume on your Mac, from 0 to 100. The Mac’s system volume stays as it is.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Volume", description: "From 0 to 100.", controlStyle: .field, inclusiveRange: (0, 100))
    var percent: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Set Music’s volume on the Mac to \(\.$percent)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let level = Double(percent) / 100
        try await ShortcutRemote.run { try await $0.setVolume(level) }
        return .result()
    }
}
