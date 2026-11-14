import Foundation
import StandByProtocol

/// Turns Music snapshots into `PlaybackMessage`s: assigns revisions and
/// listening sessions, and decides which snapshots are worth sending.
public struct PlaybackPublisher: Sendable {
    public private(set) var revisions: RevisionCounter
    public private(set) var sessions = ListeningSessionTracker()
    /// The last message handed out for sending.
    public private(set) var lastSent: PlaybackMessage?
    /// A single failed read while playing or paused is held back rather than
    /// sent, so one AppleScript hiccup doesn't cost the phone two pushes.
    public var errorsToHold = 1
    private var heldErrors = 0

    /// `resuming` is a listening session from before a restart. The first
    /// state keeps it only if Music is still playing, paused or briefly
    /// unreadable; a stop or quit in between ends it as usual.
    public init(revisions: RevisionCounter, resuming session: UUID? = nil) {
        self.revisions = revisions
        sessions = ListeningSessionTracker(current: session)
    }

    /// The newest revision handed out, or the seed before the first message.
    public var latestRevision: UInt64 { lastSent?.revision ?? revisions.current }

    /// Returns a message when the snapshot differs visibly from the last one
    /// sent, with a fresh revision. Returns nil for progress and repeats.
    /// `queue`, from Music's remote protocol, adds the catalogue ID and Up
    /// Next; Up Next alone never makes a message.
    public mutating func ingest(_ snapshot: MusicSnapshot, artworkID: String?, queue: RemoteQueue? = nil,
                                makeSessionID: () -> UUID = UUID.init) -> PlaybackMessage? {
        if snapshot.state == .error, heldErrors < errorsToHold, let last = lastSent, last.state == .playing || last.state == .paused {
            heldErrors += 1
            return nil
        }
        if snapshot.state != .error { heldErrors = 0 }

        let session = sessions.update(for: snapshot.state, makeID: makeSessionID)
        var candidate = Self.message(for: snapshot, artworkID: artworkID, queue: queue, session: session, revision: latestRevision)
        guard candidate.hasVisibleChange(from: lastSent) else { return nil }
        candidate.revision = revisions.next()
        lastSent = candidate
        return candidate
    }

    static func message(for snapshot: MusicSnapshot, artworkID: String?, queue: RemoteQueue? = nil, session: UUID?,
                        revision: UInt64) -> PlaybackMessage {
        let track = snapshot.track.map {
            TrackMetadata(id: $0.trackID, title: $0.title, artist: $0.artist, album: $0.album, duration: $0.duration, artworkID: artworkID,
                          catalogID: queue?.catalogID)
        }
        let canSkip = track != nil && (snapshot.state == .playing || snapshot.state == .paused)
        return PlaybackMessage(
            revision: revision, state: snapshot.state, elapsedTime: track == nil ? 0 : snapshot.position,
            capturedAt: StandByWire.wirePrecision(snapshot.capturedAt), track: track, canGoNext: canSkip, canGoPrevious: canSkip,
            listeningSessionID: session, detail: snapshot.detail,
            volume: snapshot.volume.map { Double($0) / 100 }, outputs: snapshot.outputs,
            upNext: track == nil ? nil : queue?.upNext)
    }
}
