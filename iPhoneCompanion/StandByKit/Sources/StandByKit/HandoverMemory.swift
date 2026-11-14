import Foundation

/// Where the Mac stopped when Continue on iPhone last took its song. After a
/// handover the Mac stays paused on that song while the phone plays on
/// through it and the queue, so without this a second Continue on iPhone,
/// such as a CarPlay automation on the next drive, started the old song
/// again (seen 15 November 2026). With it, a Mac that hasn't moved since
/// has nothing new, and Apple Music here carries on instead.
public struct HandoverMark: Codable, Equatable, Sendable {
    public var catalogID: String
    /// The Mac's position in the song when it stopped for the phone.
    public var position: TimeInterval
    public var takenAt: Date

    public init(catalogID: String, position: TimeInterval, takenAt: Date) {
        self.catalogID = catalogID
        self.position = position
        self.takenAt = takenAt
    }

    /// How far the Mac's paused position may be from `position` and still
    /// count as untouched. The position is estimated when the pause is
    /// acknowledged, a moment after Music pauses.
    static let tolerance: TimeInterval = 10

    /// True when the Mac is still paused on this song where it stopped: it
    /// hasn't played anything since the phone took it.
    public func isUntouched(by message: PlaybackMessage, at date: Date) -> Bool {
        !message.isPlaying && message.track?.catalogID == catalogID
            && abs(message.elapsed(at: date) - position) <= Self.tolerance
    }
}

/// Keeps the last `HandoverMark`. The app's button and the Shortcuts actions
/// share one, in the App Group's defaults.
@MainActor
public struct HandoverMemory {
    public var load: @MainActor () -> HandoverMark?
    public var save: @MainActor (HandoverMark?) -> Void

    public init(load: @escaping @MainActor () -> HandoverMark?, save: @escaping @MainActor (HandoverMark?) -> Void) {
        self.load = load
        self.save = save
    }

    /// Remembers nothing: every Continue on iPhone takes the Mac's song.
    public static var none: HandoverMemory {
        HandoverMemory(load: { nil }, save: { _ in })
    }

    static let key = "continueOnPhoneMark"

    public static func defaults(_ defaults: UserDefaults) -> HandoverMemory {
        HandoverMemory(
            load: { defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(HandoverMark.self, from: $0) } },
            save: { mark in
                if let mark, let data = try? JSONEncoder().encode(mark) {
                    defaults.set(data, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        )
    }

    /// The app's own, shared by the app and its Shortcuts actions.
    public static var appGroup: HandoverMemory {
        defaults(UserDefaults(suiteName: AppGroup.identifier) ?? .standard)
    }
}
