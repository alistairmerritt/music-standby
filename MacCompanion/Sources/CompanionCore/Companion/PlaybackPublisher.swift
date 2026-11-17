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
                                musicConnection: MusicConnection? = nil, makeSessionID: () -> UUID = UUID.init) -> PlaybackMessage? {
        if snapshot.state == .error, heldErrors < errorsToHold, let last = lastSent, last.state == .playing || last.state == .paused {
            heldErrors += 1
            return nil
        }
        if snapshot.state != .error { heldErrors = 0 }

        let session = sessions.update(for: snapshot.state, makeID: makeSessionID)
        var candidate = Self.message(for: snapshot, artworkID: artworkID, queue: queue, session: session, revision: latestRevision,
                                     musicConnection: musicConnection)
        // Since when the Mac plays from Apple Music outside its library: kept
        // while it goes on doing so (17 November 2026).
        if candidate.fromAppleMusic == true {
            candidate.appleMusicSince = lastSent?.fromAppleMusic == true ? lastSent?.appleMusicSince ?? candidate.capturedAt : candidate.capturedAt
        }
        guard candidate.hasVisibleChange(from: lastSent) || Self.contextChanged(candidate, from: lastSent) else { return nil }
        candidate.revision = revisions.next()
        lastSent = candidate
        return candidate
    }

    /// Shuffle, repeat or the source changed on the same song (17 November
    /// 2026): the phone needs it for Continue on iPhone. Only when both
    /// messages carry a queue read, so a slow read doesn't count.
    static func contextChanged(_ message: PlaybackMessage, from previous: PlaybackMessage?) -> Bool {
        guard let previous, message.track != nil, message.upNext != nil, previous.upNext != nil else { return false }
        return message.playlist?.name != previous.playlist?.name || message.playlist?.isShuffled != previous.playlist?.isShuffled
            || message.album?.title != previous.album?.title || message.album?.isShuffled != previous.album?.isShuffled
            || message.shuffledLibrary != previous.shuffledLibrary || message.fromAppleMusic != previous.fromAppleMusic
            || message.repeatMode != previous.repeatMode || message.shuffled != previous.shuffled
    }

    static func message(for snapshot: MusicSnapshot, artworkID: String?, queue: RemoteQueue? = nil, session: UUID?,
                        revision: UInt64, musicConnection: MusicConnection? = nil) -> PlaybackMessage {
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
            upNext: track == nil ? nil : queue?.upNext, musicConnection: musicConnection,
            playlist: track == nil ? nil : queue?.playlist, album: track == nil ? nil : queue?.album,
            shuffledLibrary: track == nil ? nil : queue?.shuffledLibrary, fromAppleMusic: track == nil ? nil : queue?.fromAppleMusic,
            repeatMode: track == nil ? nil : queue?.repeatMode, shuffled: track == nil ? nil : queue?.shuffled)
    }
}
