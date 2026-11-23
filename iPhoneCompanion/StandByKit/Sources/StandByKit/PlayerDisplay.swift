import Foundation

/// Settings' Player Display (24 November 2026): how the Mac's music shows on
/// the iPhone. One choice of three, so no contradictory combination of
/// switches is possible.
///
/// iOS doesn't tell the app reliably when it has replaced Now Playing
/// (`isSystemPrimary` read false while the player showed, and can only be
/// read while the app runs), so Automatic doesn't watch for it. It shows the
/// Live Activity at the moment iOS has most likely replaced Now Playing: when
/// the Mac plays again after a break.
public enum PlayerDisplay: String, CaseIterable, Identifiable, Sendable {
    /// Now Playing, plus the Live Activity when the Mac plays after a break.
    /// Opening the app brings Now Playing back and ends the Live Activity.
    case automatic
    /// Now Playing only.
    case nowPlaying
    /// The Live Activity only. The app doesn't ask for Now Playing.
    case liveActivity

    public var id: String { rawValue }

    /// Where it's kept, in the App Group's defaults.
    public static let key = "playerDisplay"
    /// Before Player Display: the "Keep Music Visible" switch (on unless turned off).
    static let legacyCardKey = "liveActivityCardEnabled"

    public static func current(in defaults: UserDefaults) -> PlayerDisplay {
        if let raw = defaults.string(forKey: key), let display = PlayerDisplay(rawValue: raw) { return display }
        // The switch turned off meant Now Playing alone.
        if defaults.object(forKey: legacyCardKey) as? Bool == false { return .nowPlaying }
        return .automatic
    }

    public func save(in defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.key)
    }

    /// Whether the app shows the Mac's music as Now Playing.
    public var usesNowPlaying: Bool { self != .liveActivity }
    /// Whether the relay may start the Live Activity.
    public var usesLiveActivity: Bool { self != .nowPlaying }

    public var title: String {
        switch self {
        case .automatic: "Automatic"
        case .nowPlaying: "Now Playing"
        case .liveActivity: "Live Activity"
        }
    }

    public var summary: String {
        switch self {
        case .automatic:
            "Prefer Now Playing, with a Live Activity when your Mac resumes after a break. Opening Second Chair restores Now Playing."
        case .nowPlaying:
            "Use Apple’s full music player on your Lock Screen, in the Dynamic Island and StandBy, and on Apple Watch. If iOS replaces it, open Second Chair to bring it back."
        case .liveActivity:
            "Show your Mac’s music and controls in a Live Activity on your Lock Screen and in the Dynamic Island, instead of Now Playing."
        }
    }
}
