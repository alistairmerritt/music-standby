import Foundation

/// Continue on iPhone and Continue on Mac, apart from where the Mac's state
/// comes from. The app passes in its live view of the Mac. A Shortcuts
/// action, which runs without the app's connection, passes in the relay's
/// state as read at that moment (`MacRemote`). Moved out of `AppModel` on 12
/// November 2026, so both use the same steps.
@MainActor
public struct Handover {
    /// The Mac's last state, as known now.
    var latest: @MainActor () -> PlaybackMessage?
    /// Reads the Mac's state again, so `latest` has the newest.
    var refresh: @MainActor () async -> Void
    var send: @MainActor (RemoteCommand) async throws -> CommandAck
    var record: @MainActor (String) -> Void
    var now: @Sendable () -> Date
    var sleep: @Sendable (TimeInterval) async throws -> Void

    public init(
        latest: @escaping @MainActor () -> PlaybackMessage?,
        refresh: @escaping @MainActor () async -> Void,
        send: @escaping @MainActor (RemoteCommand) async throws -> CommandAck,
        record: @escaping @MainActor (String) -> Void,
        now: @escaping @Sendable () -> Date,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void
    ) {
        self.latest = latest
        self.refresh = refresh
        self.send = send
        self.record = record
        self.now = now
        self.sleep = sleep
    }

    /// Continue on iPhone: starts the Mac's song in this phone's Apple Music
    /// at the Mac's position, with the Mac's Up Next after it, and once it's
    /// playing here, pauses the Mac. Until then the Mac keeps playing, so a
    /// failure costs nothing.
    public func continueOnPhone(with player: any PhoneMusicPlaying, timeout: TimeInterval = 10) async -> ContinueOutcome {
        guard let message = latest(), let catalogID = message.track?.catalogID else { return .unavailable }
        guard await player.requestAccess() else {
            record("Continue on iPhone: no access to Apple Music")
            return .notAllowed
        }
        let queue = [catalogID] + (message.upNext ?? []).compactMap(\.catalogID).prefix(PlaybackMessage.upNextLimit)
        let started = await player.play(catalogIDs: queue, position: { [latest, now] in
            guard let current = latest(), current.track?.catalogID == catalogID else { return message.elapsed(at: Date()) }
            return current.elapsed(at: now())
        }, timeout: timeout)
        guard started else {
            record("Continue on iPhone: Apple Music didn't start \(message.track?.title ?? "the song")")
            return .didNotStart
        }
        guard latest()?.state == .playing else {
            record("Continue on iPhone: playing here; the Mac was already paused")
            return .continued
        }
        // Once more after a second if the first try fails: the Mac can be busy
        // just then, as when headphones follow the music to the phone.
        for attempt in 1...2 {
            do {
                // The reason tells the Mac the phone has its music, so it
                // offers Continue from iPhone.
                let ack = try await send(RemoteCommand(kind: .pause, issuedAt: now(), reason: .continueOnPhone))
                if ack.accepted {
                    record("Continue on iPhone: playing here with \(queue.count - 1) songs after it; the Mac is paused")
                    return .continued
                }
                record("Continue on iPhone: the Mac refused to pause (\(ack.error?.code.rawValue ?? "no reason")), try \(attempt)")
            } catch {
                record("Continue on iPhone: couldn't pause the Mac (\(error.localizedDescription)), try \(attempt)")
            }
            if attempt == 1 { try? await sleep(1) }
        }
        return .macStillPlaying
    }

    /// How many songs ahead in the Mac's queue this catalogue ID is: 0 for
    /// the Mac's current song, 1 for the first of its Up Next. Nil when the
    /// Mac's last state doesn't have it.
    public func macQueuePosition(of catalogID: String?) -> Int? {
        guard let catalogID, let message = latest() else { return nil }
        let queue = [message.track?.catalogID] + (message.upNext ?? []).map(\.catalogID)
        return queue.firstIndex(of: catalogID)
    }

    /// Continue on Mac: the reverse of Continue on iPhone, for a song in the
    /// Mac's queue (the round trip). The Mac skips ahead to it, seeks to where
    /// the phone is and plays; once its state shows that song playing, Apple
    /// Music here pauses. Only existing commands, so it works for songs
    /// outside the Mac's library too: it's Music's own queue.
    public func sendBackToMac(with player: any PhoneMusicPlaying, timeout: TimeInterval = 10) async -> SendBackOutcome {
        // Playing or paused here: a paused song is still the phone's to hand on.
        guard let here = player.nowPlaying(), let catalogID = here.catalogID else { return .nothingPlayingHere }
        guard let ahead = macQueuePosition(of: catalogID) else {
            record("Send back to Mac: the song isn't in the Mac's queue")
            return .notInMacQueue
        }
        /// False only when the Mac says no. A reply that doesn't come in time
        /// isn't a no: the relay waits 1.2 s for the Mac, Music can take
        /// longer (as while headphones move back to the Mac), and the step
        /// usually happens anyway. The Mac's state decides below.
        func step(_ command: RemoteCommand) async -> Bool {
            do {
                let ack = try await send(command)
                if !ack.accepted { record("Send back to Mac: \(command.kind.rawValue) refused (\(ack.error?.code.rawValue ?? "no reason"))") }
                return ack.accepted
            } catch TransportError.commandRejected(let code) {
                record("Send back to Mac: \(command.kind.rawValue) refused (\(code.rawValue))")
                return false
            } catch {
                record("Send back to Mac: no answer to \(command.kind.rawValue) (\(error.localizedDescription)); carrying on")
                return true
            }
        }
        for _ in 0..<ahead {
            guard await step(RemoteCommand(kind: .next, issuedAt: now())) else { return .macRefused }
        }
        // Where the phone is now, plus about the time the seek takes to land.
        let position = (player.nowPlaying()?.position ?? here.position) + 0.3
        guard await step(.seek(to: position, issuedAt: now())), await step(RemoteCommand(kind: .play, issuedAt: now())) else {
            return .macRefused
        }
        let deadline = now().addingTimeInterval(timeout)
        while now() < deadline {
            await refresh()
            if let current = latest(), current.state == .playing, current.track?.catalogID == catalogID {
                // Headphones following the music to the Mac may have paused it already.
                if player.nowPlaying()?.isPlaying == true { player.pause() }
                record("Send back to Mac: playing on the Mac \(ahead) song\(ahead == 1 ? "" : "s") on; Apple Music here is paused")
                return .sentBack
            }
            try? await sleep(0.5)
        }
        record("Send back to Mac: the Mac didn't start the song in \(Int(timeout)) s")
        return .macDidNotStart
    }
}
