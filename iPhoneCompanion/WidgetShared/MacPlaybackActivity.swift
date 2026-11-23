import ActivityKit
import AppIntents
import Foundation

// The Live Activity card (experiment, 23 November 2026). When the Mac plays
// after a break, the relay starts this card by push, and iOS shows it on the
// Lock Screen, in the Dynamic Island and StandBy, without the app. The Now
// Playing player can't do that: a session started or updated by push stays
// hidden until the open app asks for it. Tapping the card opens the app,
// which brings the player back and ends the card.
// Records/LIVE-ACTIVITIES-FEASIBILITY.md has the reasoning.
//
// This folder is compiled into the app and the widget extension. The relay
// builds the same JSON (Relay/src/push.ts, `ActivityAttributes` and
// `ActivityContent`): keep the names in step, and the type's name too, which
// the start push names as `attributes-type`.

struct MacPlaybackActivityAttributes: ActivityAttributes {
    /// What the card shows. Times are plain numbers (Unix seconds), not
    /// `Date`s: ActivityKit decodes a `Date` as seconds since 2001.
    struct ContentState: Codable, Hashable {
        var title: String
        var artist: String
        var album: String
        /// For the artwork cache the Now Playing extension fills; "" without.
        var artworkID: String
        var isPlaying: Bool
        /// Seconds into the song at `capturedAt`.
        var elapsed: Double
        /// Unix seconds.
        var capturedAt: Double
        var duration: Double
        var canGoNext: Bool
    }

    /// The relay's id for this card; the update token is sent with it.
    var activityID: String
    var macName: String
}

extension MacPlaybackActivityAttributes.ContentState {
    /// Where the song started, as if it had played without a break: a
    /// running progress bar needs a start and an end.
    var startedAt: Date { Date(timeIntervalSince1970: capturedAt - elapsed) }
    /// The position now, for a paused card or a song of unknown length.
    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(elapsed / duration, 0), 1)
    }
    var hasSong: Bool { !title.isEmpty }
}

/// Play or pause on the Mac, from the card. A `LiveActivityIntent` runs in
/// the app's process, where `WidgetActions` is filled in, without opening it.
struct ActivityPlayPauseOnMacIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Play or Pause on Mac"
    static let description: IntentDescription? = IntentDescription("Pauses Music on your computer if it’s playing, and plays it if it isn’t.")
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let action = WidgetActions.shared.playOrPauseOnMac else { throw WidgetActionError.notReady }
        try await action()
        return .result()
    }
}

/// Next song on the Mac, from the card.
struct ActivityNextOnMacIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Next Song on Mac"
    static let description: IntentDescription? = IntentDescription("Skips to the next song in Music on your computer.")
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let action = WidgetActions.shared.nextOnMac else { throw WidgetActionError.notReady }
        try await action()
        return .result()
    }
}
