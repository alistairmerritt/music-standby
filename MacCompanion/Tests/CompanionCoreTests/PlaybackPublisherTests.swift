import Foundation
import Testing
import StandByProtocol
@testable import CompanionCore

/// Playback state transitions, as the relay will see them.
@Suite struct PlaybackPublisherTests {
    private let edge = MusicTrack(title: "Losing My Edge", artist: "LCD Soundsystem", album: "LCD Soundsystem", duration: 473.114, persistentID: "542CEB17C137B39E", artworkCount: 1)
    private let next = MusicTrack(title: "Idontknow", artist: "Jamie xx", album: "Idontknow", duration: 240.5, persistentID: "542CEB17C137B3A5")

    private func snap(_ state: PlaybackState, _ position: Double = 0, at t: Double = 1000, track: MusicTrack?? = .none) -> MusicSnapshot {
        let resolved: MusicTrack? = switch track {
        case .some(let explicit): explicit
        case .none: (state == .playing || state == .paused) ? edge : nil
        }
        return MusicSnapshot(state: state, position: position, capturedAt: Date(timeIntervalSince1970: t), track: resolved)
    }

    private func publisher() -> PlaybackPublisher {
        PlaybackPublisher(revisions: RevisionCounter(lastPersisted: nil, now: Date(timeIntervalSince1970: 1000)))
    }

    @Test func firstSnapshotIsAlwaysSent() throws {
        var p = publisher()
        let m = try must(p.ingest(snap(.paused, 10), artworkID: nil))
        #expect(m.revision == 1_000_001)
        #expect(m.state == .paused)
        #expect(m.track?.id.hasPrefix("pid:542CEB17C137B39E-") == true)
        #expect(m.listeningSessionID == nil)   // paused without having played
        #expect(m.canGoNext && m.canGoPrevious)
    }

    @Test func repeatsAndProgressAreNotSent() {
        var p = publisher()
        _ = p.ingest(snap(.playing, 10, at: 1000), artworkID: nil)
        #expect(p.ingest(snap(.playing, 10, at: 1000), artworkID: nil) == nil)
        #expect(p.ingest(snap(.playing, 12.1, at: 1002), artworkID: nil) == nil)
        #expect(p.ingest(snap(.playing, 30, at: 1020.5), artworkID: nil) == nil)
    }

    @Test func volumeAndOutputChangesAreSent() throws {
        var p = publisher()
        var snapshot = snap(.playing, 10, at: 1000)
        snapshot.volume = 50
        snapshot.outputs = [AudioOutput(id: "name:Mac", name: "Mac", kind: .computer, isSelected: true)]
        let first = try must(p.ingest(snapshot, artworkID: nil))
        #expect(first.volume == 0.5)
        #expect(first.outputs?.first?.name == "Mac")
        var same = snap(.playing, 11, at: 1001)
        same.volume = 50
        same.outputs = snapshot.outputs
        #expect(p.ingest(same, artworkID: nil) == nil)
        var quieter = snap(.playing, 12, at: 1002)
        quieter.volume = 30
        quieter.outputs = snapshot.outputs
        #expect(try must(p.ingest(quieter, artworkID: nil)).volume == 0.3)
        var moved = snap(.playing, 13, at: 1003)
        moved.volume = 30
        moved.outputs = [AudioOutput(id: "name:Mac", name: "Mac", kind: .computer, isSelected: false)]
        #expect(p.ingest(moved, artworkID: nil) != nil)
    }

    @Test func seekIsSent() {
        var p = publisher()
        _ = p.ingest(snap(.playing, 10, at: 1000), artworkID: nil)
        #expect(p.ingest(snap(.playing, 200, at: 1002), artworkID: nil) != nil)
    }

    @Test func playPauseAndSkipKeepOneSession() throws {
        var p = publisher()
        let playing = try must(p.ingest(snap(.playing, 10), artworkID: "a"))
        let session = try #require(playing.listeningSessionID)
        let paused = try must(p.ingest(snap(.paused, 11, at: 1001), artworkID: "a"))
        #expect(paused.listeningSessionID == session)
        #expect(!paused.isPlaying)
        let skipped = try must(p.ingest(snap(.paused, 0, at: 1002, track: next), artworkID: nil))
        #expect(skipped.listeningSessionID == session)
        #expect(skipped.track?.id.hasPrefix("pid:542CEB17C137B3A5-") == true)
        #expect(skipped.track?.artworkID == nil)
        #expect(playing.revision < paused.revision && paused.revision < skipped.revision)
    }

    @Test func stopEndsTheSessionAndPlayStartsANewOne() throws {
        var p = publisher()
        let first = try must(p.ingest(snap(.playing), artworkID: nil)?.listeningSessionID)
        let stopped = try must(p.ingest(snap(.stopped, at: 1001), artworkID: nil))
        #expect(stopped.listeningSessionID == nil)
        #expect(stopped.track == nil)
        #expect(!stopped.canGoNext && !stopped.canGoPrevious)
        let second = try must(p.ingest(snap(.playing, at: 1002), artworkID: nil)?.listeningSessionID)
        #expect(second != first)
    }

    /// Verified in the spike: after a restart Music is stopped with no track.
    @Test func musicRestartEndsTheSession() throws {
        var p = publisher()
        var revisions: [UInt64] = []
        let before = try must(p.ingest(snap(.playing), artworkID: nil))
        revisions.append(before.revision)
        let quit = try must(p.ingest(snap(.notRunning, at: 1001), artworkID: nil))
        #expect(quit.listeningSessionID == nil)
        revisions.append(quit.revision)
        let relaunched = try must(p.ingest(snap(.stopped, at: 1003), artworkID: nil))
        revisions.append(relaunched.revision)
        let after = try must(p.ingest(snap(.playing, at: 1010), artworkID: nil))
        revisions.append(after.revision)
        #expect(after.listeningSessionID != before.listeningSessionID)
        #expect(revisions == revisions.sorted() && Set(revisions).count == 4)
    }

    @Test func oneFailedReadIsHeldBack() throws {
        var p = publisher()
        let playing = try must(p.ingest(snap(.playing), artworkID: nil))
        let error = MusicSnapshot.failure(.error, "AppleEvent timed out. (-1712)", at: Date(timeIntervalSince1970: 1001))
        #expect(p.ingest(error, artworkID: nil) == nil)
        let second = try must(p.ingest(error, artworkID: nil))
        #expect(second.state == .error)
        #expect(second.listeningSessionID == playing.listeningSessionID)   // an error doesn't end listening
        #expect(second.detail?.contains("-1712") == true)
    }

    @Test func automationDeniedIsSentAtOnce() throws {
        var p = publisher()
        _ = p.ingest(snap(.playing), artworkID: nil)
        let denied = try must(p.ingest(.failure(.automationDenied, "-1743", at: Date(timeIntervalSince1970: 1001)), artworkID: nil))
        #expect(denied.state == .automationDenied)
        #expect(denied.listeningSessionID == nil)
    }

    @Test func artworkArrivingLaterIsAChange() {
        var p = publisher()
        _ = p.ingest(snap(.paused), artworkID: nil)
        #expect(p.ingest(snap(.paused), artworkID: "abc") != nil)
    }
}

/// `#require` captures its argument in a closure, which can't mutate `p`.
private func must<T>(_ value: T?, sourceLocation: SourceLocation = #_sourceLocation) throws -> T {
    try #require(value, sourceLocation: sourceLocation)
}

@Suite struct ListeningSessionResumeTests {
    private let track = MusicTrack(title: "T", artist: "A", album: "B", duration: 100, persistentID: "X")
    private let saved = UUID()

    private func publisher() -> PlaybackPublisher {
        PlaybackPublisher(revisions: RevisionCounter(lastPersisted: nil, now: Date(timeIntervalSince1970: 1000)), resuming: saved)
    }

    /// Found end to end: a companion restart mid-song gave the phone a new session.
    @Test func restartDuringPlaybackKeepsTheSession() throws {
        var p = publisher()
        let m = try must(p.ingest(MusicSnapshot(state: .playing, position: 5, capturedAt: Date(), track: track), artworkID: nil))
        #expect(m.listeningSessionID == saved)
        var paused = publisher()
        #expect(paused.ingest(MusicSnapshot(state: .paused, capturedAt: Date(), track: track), artworkID: nil)?.listeningSessionID == saved)
    }

    @Test func aStopWhileTheCompanionWasDownStillEndsIt() throws {
        var p = publisher()
        #expect(p.ingest(MusicSnapshot(state: .stopped, capturedAt: Date()), artworkID: nil)?.listeningSessionID == nil)
        let next = try must(p.ingest(MusicSnapshot(state: .playing, capturedAt: Date(), track: track), artworkID: nil))
        #expect(next.listeningSessionID != saved)
    }

    @Test func storeForgetsOldSessions() {
        let store = CompanionStore(defaults: UserDefaults(suiteName: "resume-\(UUID().uuidString)")!)
        let id = UUID()
        store.saveListeningSession(id, now: Date(timeIntervalSince1970: 1000))
        #expect(store.listeningSession(now: Date(timeIntervalSince1970: 1300)) == id)
        #expect(store.listeningSession(now: Date(timeIntervalSince1970: 2000)) == nil)
        store.saveListeningSession(nil)
        #expect(store.listeningSession(now: Date(timeIntervalSince1970: 1001)) == nil)
    }
}
