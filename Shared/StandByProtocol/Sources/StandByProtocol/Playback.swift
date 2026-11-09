import Foundation

/// What Music.app is doing, as the Mac reports it. Raw values match the
/// prototype's `musicprobe.sh` JSON.
public enum PlaybackState: String, Codable, Sendable, CaseIterable {
    case playing
    case paused
    /// Music is running with nothing loaded, or playback was stopped.
    case stopped
    /// Music.app is not running. The Mac never launches it to find out.
    case notRunning = "not_running"
    /// AppleScript error -1743. Lasts until the user allows the companion in
    /// System Settings → Privacy & Security → Automation.
    case automationDenied = "automation_denied"
    /// Music is running but could not be read. Usually transient.
    case error

    public var isPlaying: Bool { self == .playing }

    /// Whether an open listening session survives this state. A pause or a
    /// one-off read error does not end listening; a stop, a quit or a refused
    /// permission does.
    public var continuesSession: Bool {
        switch self {
        case .playing, .paused, .error: true
        case .stopped, .notRunning, .automationDenied: false
        }
    }
}

/// One snapshot of the Mac's playback, sent whenever something visible changes.
///
/// Keeps every field of the iOS app's temporary `PlaybackMessage`, so existing
/// call sites compile unchanged, and adds `state`, `listeningSessionID` and
/// `detail`. JSON without `state` (the temporary contract) still decodes.
public struct PlaybackMessage: Codable, Equatable, Sendable {
    /// Strictly increasing for one Mac, across restarts of the companion app.
    /// See `RevisionCounter`. A re-send of an unchanged snapshot may repeat it.
    public var revision: UInt64
    public var state: PlaybackState
    /// Playback position in seconds at `capturedAt`.
    public var elapsedTime: TimeInterval
    /// When `elapsedTime` was read. Receivers extrapolate from here while playing.
    public var capturedAt: Date
    /// Nil when nothing is loaded, including whenever Music is not running.
    public var track: TrackMetadata?
    public var canGoNext: Bool
    public var canGoPrevious: Bool
    /// One run of listening: minted when playback starts with no session open,
    /// kept across track changes and pauses, cleared on stop or quit. Not the
    /// song (that is `track.id`) and not the relay's Now Playing session id.
    public var listeningSessionID: UUID?
    /// Diagnostic text for `.automationDenied` and `.error`. Never shown raw to
    /// a user on the phone.
    public var detail: String?

    /// Encoded for the temporary contract and for JavaScript readers. Always
    /// equal to `state == .playing`.
    public var isPlaying: Bool { state.isPlaying }

    public init(revision: UInt64, state: PlaybackState, elapsedTime: TimeInterval, capturedAt: Date, track: TrackMetadata?,
                canGoNext: Bool, canGoPrevious: Bool, listeningSessionID: UUID? = nil, detail: String? = nil) {
        self.revision = revision
        self.state = state
        self.elapsedTime = elapsedTime
        self.capturedAt = capturedAt
        self.track = track
        self.canGoNext = canGoNext
        self.canGoPrevious = canGoPrevious
        self.listeningSessionID = listeningSessionID
        self.detail = detail
    }

    /// The temporary contract's initialiser. A non-playing message with a
    /// track is `.paused`; without one it is `.stopped`.
    public init(revision: UInt64, isPlaying: Bool, elapsedTime: TimeInterval, capturedAt: Date, track: TrackMetadata?, canGoNext: Bool, canGoPrevious: Bool) {
        self.init(revision: revision, state: Self.legacyState(isPlaying: isPlaying, track: track), elapsedTime: elapsedTime,
                  capturedAt: capturedAt, track: track, canGoNext: canGoNext, canGoPrevious: canGoPrevious)
    }

    private static func legacyState(isPlaying: Bool, track: TrackMetadata?) -> PlaybackState {
        isPlaying ? .playing : (track == nil ? .stopped : .paused)
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case revision, state, isPlaying, elapsedTime, capturedAt, track, canGoNext, canGoPrevious, listeningSessionID, detail
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        revision = try c.decode(UInt64.self, forKey: .revision)
        elapsedTime = try c.decode(TimeInterval.self, forKey: .elapsedTime)
        capturedAt = try c.decode(Date.self, forKey: .capturedAt)
        track = try c.decodeIfPresent(TrackMetadata.self, forKey: .track)
        canGoNext = try c.decode(Bool.self, forKey: .canGoNext)
        canGoPrevious = try c.decode(Bool.self, forKey: .canGoPrevious)
        listeningSessionID = try c.decodeIfPresent(UUID.self, forKey: .listeningSessionID)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        // `state` wins when present. Without it this is the temporary contract.
        if let state = try c.decodeIfPresent(PlaybackState.self, forKey: .state) {
            self.state = state
        } else {
            state = Self.legacyState(isPlaying: try c.decode(Bool.self, forKey: .isPlaying), track: track)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(revision, forKey: .revision)
        try c.encode(state, forKey: .state)
        try c.encode(isPlaying, forKey: .isPlaying)
        try c.encode(elapsedTime, forKey: .elapsedTime)
        try c.encode(capturedAt, forKey: .capturedAt)
        try c.encodeIfPresent(track, forKey: .track)
        try c.encode(canGoNext, forKey: .canGoNext)
        try c.encode(canGoPrevious, forKey: .canGoPrevious)
        try c.encodeIfPresent(listeningSessionID, forKey: .listeningSessionID)
        try c.encodeIfPresent(detail, forKey: .detail)
    }
}

extension PlaybackMessage {
    /// Position at `date`: extrapolated while playing, clamped to the track.
    /// Same rule as `MacPlaybackAttributes.elapsed(at:)` on iOS.
    public func elapsed(at date: Date) -> TimeInterval {
        let running = isPlaying ? max(0, date.timeIntervalSince(capturedAt)) : 0
        let position = max(0, elapsedTime + running)
        guard let duration = track?.duration, duration > 0 else { return position }
        return min(position, duration)
    }

    /// The receiver's ordering rule: take `incoming` unless it is older. An equal
    /// revision is a re-send of the same snapshot and is harmless to apply.
    public func isSuperseded(by incoming: PlaybackMessage) -> Bool {
        incoming.revision >= revision
    }

    /// Whether `self` differs from `previous` in a way a viewer could see.
    /// Ordinary progress is not a change; a seek is, once the position moves
    /// further than `positionTolerance` from where `previous` predicts.
    /// The Mac sends only on these, and the relay can coalesce on the same rule.
    public func hasVisibleChange(from previous: PlaybackMessage?, positionTolerance: TimeInterval = 2) -> Bool {
        guard let previous else { return true }
        if state != previous.state || track != previous.track || canGoNext != previous.canGoNext
            || canGoPrevious != previous.canGoPrevious || listeningSessionID != previous.listeningSessionID {
            return true
        }
        guard track != nil, state == .playing || state == .paused else { return false }
        return abs(elapsedTime - previous.elapsed(at: capturedAt)) > positionTolerance
    }
}
