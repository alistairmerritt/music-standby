import Foundation
import WidgetKit

/// What the Continue Listening widget shows: the Mac's song as last heard,
/// in the App Group, written by the app and the Now Playing extension
/// (22 November 2026). A widget isn't live; this is its picture.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public var macName: String
    public var title: String?
    public var artist: String?
    public var album: String?
    /// For `ArtworkStore` / `MockArtwork`; nil without artwork.
    public var artworkID: String?
    public var macPlaying: Bool
    /// Continue on iPhone took this song, and the Mac hasn't played since.
    public var onIPhone: Bool
    public var updatedAt: Date

    public init(macName: String, title: String? = nil, artist: String? = nil, album: String? = nil, artworkID: String? = nil,
                macPlaying: Bool = false, onIPhone: Bool = false, updatedAt: Date = Date()) {
        self.macName = macName
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkID = artworkID
        self.macPlaying = macPlaying
        self.onIPhone = onIPhone
        self.updatedAt = updatedAt
    }

    /// The widget's kind, for reloads.
    public static let kind = "ContinueListening"
    static let key = "widget.snapshot"

    public static var defaults: UserDefaults { UserDefaults(suiteName: AppGroup.identifier) ?? .standard }

    public static func load(from defaults: UserDefaults = WidgetSnapshot.defaults) -> WidgetSnapshot? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(WidgetSnapshot.self, from: $0) }
    }

    /// The Mac's state as a snapshot. "On iPhone" carries over from `previous`
    /// while the Mac stays paused on the same song.
    public static func from(_ attributes: MacPlaybackAttributes, previous: WidgetSnapshot?, now: Date = Date()) -> WidgetSnapshot {
        let track = attributes.track
        let sameSong = previous?.title == track?.title && previous?.artist == track?.artist
        return WidgetSnapshot(macName: attributes.macName, title: track?.title, artist: track?.artist, album: track?.album,
                              artworkID: track?.artworkReference, macPlaying: attributes.isPlaying,
                              onIPhone: !attributes.isPlaying && sameSong && (previous?.onIPhone ?? false), updatedAt: now)
    }

    /// Whether the widget would draw anything different: the clock alone
    /// isn't worth one of iOS's rationed reloads.
    func looksDifferent(from other: WidgetSnapshot?) -> Bool {
        guard let other else { return true }
        var a = self, b = other
        a.updatedAt = .distantPast
        b.updatedAt = .distantPast
        return a != b
    }

    /// Saves, and reloads the widget only if it would look different.
    public static func publish(_ snapshot: WidgetSnapshot, to defaults: UserDefaults = WidgetSnapshot.defaults) {
        let previous = load(from: defaults)
        guard snapshot.looksDifferent(from: previous), let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key)
        WidgetCenter.shared.reloadTimelines(ofKind: kind)
    }

    /// From the Mac's latest attributes.
    public static func publish(_ attributes: MacPlaybackAttributes, to defaults: UserDefaults = WidgetSnapshot.defaults) {
        publish(from(attributes, previous: load(from: defaults)), to: defaults)
    }

    /// After a hand-over: the iPhone has the music (true) or the Mac has it back (false).
    public static func markOnIPhone(_ onIPhone: Bool, in defaults: UserDefaults = WidgetSnapshot.defaults) {
        guard var snapshot = load(from: defaults) else { return }
        snapshot.onIPhone = onIPhone
        if onIPhone { snapshot.macPlaying = false }
        publish(snapshot, to: defaults)
    }
}
