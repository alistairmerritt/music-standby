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
    /// Where the Mac stopped when Continue on iPhone last took its song.
    var memory: HandoverMemory

    public init(
        latest: @escaping @MainActor () -> PlaybackMessage?,
        refresh: @escaping @MainActor () async -> Void,
        send: @escaping @MainActor (RemoteCommand) async throws -> CommandAck,
        record: @escaping @MainActor (String) -> Void,
        now: @escaping @Sendable () -> Date,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void,
        memory: HandoverMemory
    ) {
        self.latest = latest
        self.refresh = refresh
        self.send = send
        self.record = record
        self.now = now
        self.sleep = sleep
        self.memory = memory
    }

    /// Continue on iPhone: starts the Mac's song in this phone's Apple Music
    /// at the Mac's position, with the Mac's Up Next after it, and once it's
    /// playing here, pauses the Mac. Until then the Mac keeps playing, so a
    /// failure costs nothing.
    ///
    /// When the Mac hasn't moved since the last time (still paused on the
    /// song this phone took, where it stopped), it has nothing new, and
    /// Apple Music here, which has played on since, carries on instead.
    public func continueOnPhone(with player: any PhoneMusicPlaying, timeout: TimeInterval = 10) async -> ContinueOutcome {
        guard let message = latest(), let track = message.track else { return .unavailable }
        guard let catalogID = await catalogID(for: track, with: player) else {
            record("Continue on iPhone: \(track.title) isn't in the Apple Music catalogue")
            return .unavailable
        }
        if let mark = memory.load(), mark.isUntouched(by: message, at: now()), let here = player.nowPlaying() {
            if here.isPlaying {
                record("Continue on iPhone: already playing here; nothing new on the Mac since it was continued")
                return .alreadyPlayingHere
            }
            player.resume()
            record("Continue on iPhone: resumed Apple Music here; nothing new on the Mac since it was continued")
            return .resumedHere
        }
        guard await player.requestAccess() else {
            record("Continue on iPhone: no access to Apple Music")
            return .notAllowed
        }
        let position: @MainActor () -> TimeInterval = { [latest, now] in
            guard let current = latest(), current.track?.catalogID == catalogID else { return message.elapsed(at: Date()) }
            return current.elapsed(at: now())
        }
        // The Mac's playlist itself when Up Next is the rest of it, rather
        // than the next 25 of its songs (17 November 2026).
        if let place = message.playlist, place.isValid, !place.isShuffled {
            if let played = await player.play(catalogID, in: place, position: position, timeout: min(timeout, Self.playlistStartWait)) {
                memory.savePlaylist(played)
                let songsAfter = played.count - played.index - 1
                record("Continue on iPhone: the Mac's playlist plays here, from song \(played.index + 1) of \(played.count)")
                let outcome = await pauseMac(for: catalogID, songsAfter: songsAfter)
                if songsAfter < Self.stationBelow {
                    await followWithStation(seededBy: catalogID, songsAfter: songsAfter, from: "the playlist", with: player)
                }
                return outcome
            }
            record("Continue on iPhone: the Mac's playlist isn't here with the song; its next songs instead")
        }
        memory.savePlaylist(nil)
        let queue = [catalogID] + (message.upNext ?? []).compactMap(\.catalogID).prefix(PlaybackMessage.upNextLimit)
        let started = await player.play(catalogIDs: queue, position: position, timeout: timeout)
        guard started else {
            record("Continue on iPhone: Apple Music didn't start \(message.track?.title ?? "the song")")
            return .didNotStart
        }
        let outcome = await pauseMac(for: catalogID, songsAfter: queue.count - 1)
        if queue.count - 1 < Self.stationBelow {
            await followWithStation(seededBy: catalogID, songsAfter: queue.count - 1, with: player)
        }
        return outcome
    }

    /// The Mac's catalogue ID, or, when the Mac has none, the phone's own
    /// Apple Music search. The Mac looks songs outside the library up in
    /// Apple's public search, which doesn't have some (Daniel Caesar's
    /// "Japanese Denim", 16 November 2026, only covers); the phone's Apple
    /// Music catalogue does.
    private func catalogID(for track: TrackMetadata, with player: any PhoneMusicPlaying) async -> String? {
        if let id = track.catalogID { return id }
        guard await player.requestAccess() else { return nil }
        let candidates = await player.searchCatalog(title: track.title, artist: track.artist)
        let found = CatalogCandidate.best(title: track.title, artist: track.artist, duration: track.duration, in: candidates)
        record(found == nil ? "Continue on iPhone: no catalogue match here for \(track.title)" : "Continue on iPhone: found \(track.title) in the catalogue here")
        return found?.id
    }

    /// How long the Mac's playlist may take to start here before Continue on
    /// iPhone takes the Mac's next songs instead. It started in 0.16 s on
    /// 17 November 2026.
    static let playlistStartWait: TimeInterval = 6

    /// With fewer songs than this to come on the Mac, a station made from
    /// the song follows them here. A station on the Mac lists only its next
    /// song, so the phone stopped after it (seen 15 November 2026, from a
    /// CarPlay automation); an album can be ending too. The Mac can't say
    /// which station it plays (neither AppleScript nor Music's remote
    /// protocol names it), so this is Apple Music's station for the song.
    static let stationBelow = 3

    private func followWithStation(seededBy catalogID: String, songsAfter: Int, from source: String = "the Mac",
                                   with player: any PhoneMusicPlaying) async {
        let result = await player.appendStation(seededBy: catalogID)
        switch result {
        case .added: record("Continue on iPhone: \(songsAfter) song\(songsAfter == 1 ? "" : "s") from \(source), then a station from the song")
        case .noStation: record("Continue on iPhone: Apple Music has no station for the song")
        case .failed(let reason): record("Continue on iPhone: couldn't add a station (\(reason))")
        }
    }

    /// Once the song plays here: the Mac pauses, and learns from the
    /// command's reason that the phone has its music.
    private func pauseMac(for catalogID: String, songsAfter: Int) async -> ContinueOutcome {
        // The pause goes to a paused Mac too: its reason is how the Mac learns
        // the phone has its music, to offer Continue from iPhone, and Music
        // ignores a pause while paused. Only a playing Mac is worth a retry.
        guard latest()?.state == .playing else {
            let ack = try? await send(RemoteCommand(kind: .pause, issuedAt: now(), reason: .continueOnPhone))
            remember(catalogID)
            record("Continue on iPhone: playing here; the Mac was already paused\(ack?.accepted == true ? " and knows" : "")")
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
                    remember(catalogID)
                    record("Continue on iPhone: playing here with \(songsAfter) songs after it; the Mac is paused")
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

    /// Where the Mac stopped for this phone: its position run on to now, as
    /// the pause has only just landed.
    private func remember(_ catalogID: String) {
        guard let current = latest(), current.track?.catalogID == catalogID else { return memory.save(nil) }
        memory.save(HandoverMark(catalogID: catalogID, position: current.elapsed(at: now()), takenAt: now()))
    }

    /// How many songs ahead in the Mac's queue this catalogue ID is: 0 for
    /// the Mac's current song, 1 for the first of its Up Next. Nil when the
    /// Mac's last state doesn't have it.
    public func macQueuePosition(of catalogID: String?) -> Int? {
        guard let catalogID, let message = latest() else { return nil }
        let queue = [message.track?.catalogID] + (message.upNext ?? []).map(\.catalogID)
        return queue.firstIndex(of: catalogID)
    }

    /// Continue on Mac: the reverse of Continue on iPhone. For a song in the
    /// Mac's queue (the round trip), the Mac skips ahead to it, seeks to where
    /// the phone is and plays; once its state shows that song playing, Apple
    /// Music here pauses. Only existing commands, so it works for songs
    /// outside the Mac's library too: it's Music's own queue. Any other
    /// song goes over as its station (`sendAsStation`).
    ///
    /// From 17 November 2026, a song goes with the library playlist the
    /// phone plays it from, when the phone can tell, unless it's at most
    /// `skipsAtMost` songs into the Mac's queue and that queue is the same
    /// playlist: the Mac plays the playlist from the song, which is quicker
    /// than many skips and carries on after the 25 songs it sent.
    public func sendBackToMac(with player: any PhoneMusicPlaying, timeout: TimeInterval = 10) async -> SendBackOutcome {
        // Playing or paused here: a paused song is still the phone's to hand on.
        guard let here = player.nowPlaying(), let catalogID = here.catalogID else { return .nothingPlayingHere }
        let ahead = macQueuePosition(of: catalogID)
        let place = await player.playlistPlace(remembered: memory.loadPlaylist())
        // Not from a playlist: perhaps an album (17 November 2026).
        let album = place == nil ? await player.albumPlace() : nil
        // The Mac's own queue when it's the phone's playlist or album (the
        // round trip) or the phone has neither; else the phone's, even for a
        // song the Mac has, as when the Mac plays the song's station.
        let sameAsTheMac: Bool
        if let place {
            sameAsTheMac = latest()?.playlist?.name == place.name
        } else if let album {
            sameAsTheMac = latest()?.track?.album == album.title
        } else {
            sameAsTheMac = true
        }
        if let ahead, (place == nil && album == nil) || (ahead <= Self.skipsAtMost && sameAsTheMac) {
            return await skipMacAhead(ahead, to: catalogID, here: here, with: player, timeout: timeout)
        }
        if let place {
            record("Send back to Mac: the phone's playlist, from song \(place.index + 1) of \(place.count)\(place.isShuffled ? ", shuffled" : "")")
        } else if let album {
            record("Send back to Mac: the phone's album, from song \(album.index + 1) of \(album.count)\(album.isShuffled ? ", shuffled here; in order on the Mac" : "")")
        }
        return await sendAsStation(here, catalogID: catalogID, playlist: place, album: album, with: player,
                                   timeout: timeout + Self.stationStartAllowance)
    }

    /// Songs the Mac may skip through to reach the phone's song, rather than
    /// start the phone's playlist from it.
    static let skipsAtMost = 2

    /// The round trip: the Mac skips ahead in its own queue to the phone's song.
    private func skipMacAhead(_ ahead: Int, to catalogID: String, here: PhoneNowPlaying, with player: any PhoneMusicPlaying,
                              timeout: TimeInterval) async -> SendBackOutcome {
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
                // The Mac has the music again: the next Continue on iPhone takes it.
                memory.save(nil)
                record("Send back to Mac: playing on the Mac \(ahead) song\(ahead == 1 ? "" : "s") on; Apple Music here is paused")
                return .sentBack
            }
            try? await sleep(0.5)
        }
        record("Send back to Mac: the Mac didn't start the song in \(Int(timeout)) s")
        return .macDidNotStart
    }

    /// A station takes longer to start than a skip in the queue.
    static let stationStartAllowance: TimeInterval = 5

    /// Continue on Mac for a song the Mac's queue doesn't have, as once the
    /// phone has played past it (a station after the Mac's songs, seen 15
    /// November 2026). Music on the Mac can't be told to play a catalogue
    /// song outside the library, but it plays the song's station, which
    /// usually starts with the song (2 of 3 tried). Then the Mac seeks to
    /// where the phone is; otherwise it plays on from the station's first
    /// song. Either way Apple Music here pauses once the Mac plays.
    ///
    /// With `playlist`, a Mac connected to Music that has it plays the
    /// playlist from the song instead, which starts with the song every
    /// time; an older Mac, or one without the playlist, plays the station.
    private func sendAsStation(_ here: PhoneNowPlaying, catalogID: String, playlist: PlaylistPlace? = nil, album: AlbumPlace? = nil,
                               with player: any PhoneMusicPlaying, timeout: TimeInterval) async -> SendBackOutcome {
        let before = latest()
        // Where the phone is and the song's title, so the Mac can seek itself
        // the moment Music starts the song (16 November 2026).
        let position = player.nowPlaying()?.position ?? here.position
        guard await step(.playStation(seededBy: catalogID, position: position, title: here.title, playlist: playlist, album: album,
                                      issuedAt: now())) else {
            return .macRefused
        }
        let deadline = now().addingTimeInterval(timeout)
        while now() < deadline {
            await refresh()
            if let current = latest(), current.state == .playing, let track = current.track,
               current.revision > (before?.revision ?? 0), track.id != before?.track?.id || track.catalogID == catalogID {
                let sameSong = track.catalogID == catalogID
                    || (track.catalogID == nil && here.title.map { track.title.caseInsensitiveCompare($0) == .orderedSame } == true)
                if sameSong { await seekIfTheMacMissedIt(player: player, here: here) }
                if player.nowPlaying()?.isPlaying == true { player.pause() }
                memory.save(nil)
                let what = playlist != nil ? "the song's playlist (or its station)" : album != nil ? "the song's album (or its station)" : "the song's station"
                record(sameSong ? "Send back to Mac: \(what) plays on the Mac from the same point; Apple Music here is paused"
                                : "Send back to Mac: \(what) plays on the Mac, from another song; Apple Music here is paused")
                return sameSong ? .sentBack : .sentAsStation
            }
            try? await sleep(0.5)
        }
        record("Send back to Mac: the Mac didn't start the song's station in \(Int(timeout)) s")
        return .macDidNotStart
    }

    /// How far the Mac may be from the phone and still count as there.
    static let seekTolerance: TimeInterval = 3

    /// The Mac seeks itself once the station starts with the song. A Mac
    /// from before 16 November 2026 doesn't, and a seek can go astray, so
    /// give its seek a moment to show, then seek from here if it's still off.
    private func seekIfTheMacMissedIt(player: any PhoneMusicPlaying, here: PhoneNowPlaying) async {
        func gap() -> TimeInterval? {
            guard let mac = latest() else { return nil }
            return abs(mac.elapsed(at: now()) - (player.nowPlaying()?.position ?? here.position))
        }
        for attempt in 0..<4 {
            if let gap = gap(), gap <= Self.seekTolerance { return }
            if attempt < 3 {
                try? await sleep(0.5)
                await refresh()
            }
        }
        // Where the phone is now, plus about the time the seek takes to land.
        let position = (player.nowPlaying()?.position ?? here.position) + 0.3
        record("Send back to Mac: the Mac didn't seek to the phone's point; seeking from here")
        _ = await step(.seek(to: position, issuedAt: now()))
    }

    /// False only when the Mac says no. A reply that doesn't come in time
    /// isn't a no: the relay waits 1.2 s for the Mac, Music can take longer
    /// (as while headphones move back to the Mac), and the step usually
    /// happens anyway. The Mac's state decides afterwards.
    private func step(_ command: RemoteCommand) async -> Bool {
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
}
