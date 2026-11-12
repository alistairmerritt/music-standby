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
    static let description: IntentDescription? = IntentDescription("Jumps to a point in the song playing on your Mac, such as 2 minutes in. A time past the end goes to the end.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Time", defaultUnit: .seconds, supportsNegativeNumbers: false)
    var time: Measurement<UnitDuration>

    static var parameterSummary: some ParameterSummary {
        Summary("Jump to \(\.$time) into the Mac’s song")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let seconds = time.converted(to: .seconds).value
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

struct PlayToSpeakerIntent: AppIntent {
    static let title: LocalizedStringResource = "Play To"
    static let description: IntentDescription? = IntentDescription("Chooses where your Mac plays Music: its own speakers, a HomePod, an Apple TV, AirPods or another AirPlay speaker. Music plays to that one alone.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Speaker")
    var speaker: MacSpeaker

    static var parameterSummary: some ParameterSummary {
        Summary("Play the Mac’s music to \(\.$speaker)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let id = speaker.id
        let output = try await ShortcutRemote.run { try await $0.playTo(id) }
        return .result(dialog: "Switching to \(output.name).")
    }
}

/// One of the places the Mac can play to, from its last state. Saved in a
/// shortcut by its ID, which stays the same between runs: the speaker's
/// network address, or its name when Music doesn't give one.
struct MacSpeaker: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Speaker"
    static let defaultQuery = MacSpeakerQuery()

    let id: String
    let name: String
    let kind: AudioOutput.Kind
    let isSelected: Bool
    let isAvailable: Bool

    init(_ output: AudioOutput) {
        id = output.id
        name = output.name
        kind = output.kind
        isSelected = output.isSelected
        isAvailable = output.isAvailable
    }

    /// A speaker a shortcut remembers that the Mac doesn't list right now,
    /// such as AirPods that aren't nearby. Running the action then says so.
    init(remembered id: String) {
        self.id = id
        name = id.hasPrefix("name:") ? String(id.dropFirst("name:".count)) : "Speaker"
        kind = .unknown
        isSelected = false
        isAvailable = false
    }

    var displayRepresentation: DisplayRepresentation {
        let subtitle: LocalizedStringResource? = isSelected ? "Playing now" : (isAvailable ? nil : "Not available now")
        return DisplayRepresentation(title: "\(name)", subtitle: subtitle, image: DisplayRepresentation.Image(systemName: kind.symbolName))
    }
}

struct MacSpeakerQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [MacSpeaker] {
        // Shown in the shortcut editor too, so a Mac that can't be reached
        // just now mustn't make a saved speaker disappear.
        let outputs = (try? await ShortcutRemote.run { try await $0.outputs() }) ?? []
        return identifiers.map { id in outputs.first { $0.id == id }.map(MacSpeaker.init) ?? MacSpeaker(remembered: id) }
    }

    @MainActor
    func suggestedEntities() async throws -> [MacSpeaker] {
        try await ShortcutRemote.run { try await $0.outputs() }.map(MacSpeaker.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [MacSpeaker] {
        try await suggestedEntities().filter { $0.name.localizedStandardContains(string) }
    }
}
