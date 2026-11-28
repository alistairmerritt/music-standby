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

/// Keeps the last `HandoverMark`, and the playlist Continue on iPhone last
/// started here. The app's button and the Shortcuts actions share them, in
/// the App Group's defaults.
@MainActor
public struct HandoverMemory {
    public var load: @MainActor () -> HandoverMark?
    public var save: @MainActor (HandoverMark?) -> Void
    /// The library playlist Continue on iPhone last played here, for the way
    /// back: Apple Music lists it as recently played only after about a
    /// minute (17 November 2026). Checked against Music's queue before use.
    public var loadPlaylist: @MainActor () -> PlaylistPlace?
    public var savePlaylist: @MainActor (PlaylistPlace?) -> Void
    /// The library album Continue on iPhone last played here (19 November
    /// 2026), for the same reason: a shuffled album an app queued is in no
    /// recently played list, and the way back sent the library shuffled.
    public var loadAlbum: @MainActor () -> AlbumPlace?
    public var saveAlbum: @MainActor (AlbumPlace?) -> Void
    /// Settings › When a playlist or album isn't in your library (28
    /// November 2026; was the switch "Add Playlists and Albums to Library").
    /// Continue on Mac asks, adds, or plays the song's station.
    public var libraryPreference: @MainActor () -> LibraryPreference
    /// Remember my choice.
    public var saveLibraryPreference: @MainActor (LibraryPreference) -> Void
    /// The catalogue IDs Continue on iPhone last queued here from the Mac's
    /// Up Next (17 November 2026). A song from them isn't from any playlist,
    /// album or station Apple Music lists as recently played, which is
    /// account-wide: an old station there once looked current.
    public var loadQueued: @MainActor () -> [String]?
    public var saveQueued: @MainActor ([String]?) -> Void

    public init(load: @escaping @MainActor () -> HandoverMark?, save: @escaping @MainActor (HandoverMark?) -> Void,
                loadPlaylist: @escaping @MainActor () -> PlaylistPlace? = { nil },
                savePlaylist: @escaping @MainActor (PlaylistPlace?) -> Void = { _ in },
                loadAlbum: @escaping @MainActor () -> AlbumPlace? = { nil },
                saveAlbum: @escaping @MainActor (AlbumPlace?) -> Void = { _ in },
                libraryPreference: @escaping @MainActor () -> LibraryPreference = { .ask },
                saveLibraryPreference: @escaping @MainActor (LibraryPreference) -> Void = { _ in },
                loadQueued: @escaping @MainActor () -> [String]? = { nil },
                saveQueued: @escaping @MainActor ([String]?) -> Void = { _ in }) {
        self.load = load
        self.save = save
        self.loadPlaylist = loadPlaylist
        self.savePlaylist = savePlaylist
        self.loadAlbum = loadAlbum
        self.saveAlbum = saveAlbum
        self.libraryPreference = libraryPreference
        self.saveLibraryPreference = saveLibraryPreference
        self.loadQueued = loadQueued
        self.saveQueued = saveQueued
    }

    /// The App Group key for `libraryPreference`: a `LibraryPreference` raw value.
    public static let libraryPreferenceKey = "continueOnMacLibraryChoice"
    /// The old switch's key (17–27 November 2026), read once by
    /// `migrateLibraryPreference` and otherwise left alone, so an older build
    /// installed over this one still finds its setting.
    public static let addsToLibraryKey = "continueOnMacAddsToLibrary"

    /// The setting, migrated from the old switch the first time it's read.
    /// The switch was stored only once someone flipped it (`@AppStorage`
    /// writes nothing for its default), so a stored value is a choice:
    /// on → Add to Library; on and then off again → Play Song Station Instead, as
    /// that's what they had. Never touched → Ask Every Time, the new default,
    /// since nobody chose the station; they just never saw the switch.
    @discardableResult
    public static func migrateLibraryPreference(in defaults: UserDefaults) -> LibraryPreference {
        if let raw = defaults.string(forKey: libraryPreferenceKey), let preference = LibraryPreference(rawValue: raw) {
            return preference
        }
        let preference: LibraryPreference = switch defaults.object(forKey: addsToLibraryKey) as? Bool {
        case true?: .add
        case false?: .station
        case nil: .ask
        }
        defaults.set(preference.rawValue, forKey: libraryPreferenceKey)
        return preference
    }

    /// Remembers nothing: every Continue on iPhone takes the Mac's song.
    public static var none: HandoverMemory {
        HandoverMemory(load: { nil }, save: { _ in })
    }

    static let key = "continueOnPhoneMark"
    static let playlistKey = "continueOnPhonePlaylist"
    static let albumKey = "continueOnPhoneAlbum"
    static let queuedKey = "continueOnPhoneQueued"

    public static func defaults(_ defaults: UserDefaults) -> HandoverMemory {
        func load<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
            defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
        }
        func save<T: Encodable>(_ value: T?, _ key: String) {
            if let value, let data = try? JSONEncoder().encode(value) {
                defaults.set(data, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        return HandoverMemory(load: { load(HandoverMark.self, key) }, save: { save($0, key) },
                              loadPlaylist: { load(PlaylistPlace.self, playlistKey) }, savePlaylist: { save($0, playlistKey) },
                              loadAlbum: { load(AlbumPlace.self, albumKey) }, saveAlbum: { save($0, albumKey) },
                              libraryPreference: { migrateLibraryPreference(in: defaults) },
                              saveLibraryPreference: { defaults.set($0.rawValue, forKey: libraryPreferenceKey) },
                              loadQueued: { load([String].self, queuedKey) }, saveQueued: { save($0, queuedKey) })
    }

    /// The app's own, shared by the app and its Shortcuts actions.
    public static var appGroup: HandoverMemory {
        defaults(UserDefaults(suiteName: AppGroup.identifier) ?? .standard)
    }
}
