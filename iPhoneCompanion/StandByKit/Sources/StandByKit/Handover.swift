import Foundation

/// Continue on iPhone and Continue on Mac, apart from where the Mac's state
/// comes from. The app passes in its live view of the Mac. A Shortcuts
/// action, which runs without the app's connection, passes in the relay's
/// state as read at that moment (`MacRemote`). Moved out of `AppModel` on 12
/// November 2026, so both use the same steps.
/// Where a hand-over was started from, for the Lock Screen Record.
public enum HandoverSource: String, Sendable {
    case app = "the app"
    case widget = "a widget or control"
    case shortcuts = "Shortcuts"
    case macRequest = "the Mac’s Continue from iPhone"
    case unknown = "somewhere unknown"
}

@MainActor
public struct Handover {
    /// Called once, the moment the music moves: when it starts on the phone,
    /// or when the Mac is seen playing it. The rest of a hand-over (pausing
    /// the other side, a station to follow, a seek) carries on after it, so
    /// Home's animation lands with the sound rather than seconds later
    /// (23 November 2026).
    @MainActor final class Arrival {
        var call: (@MainActor () -> Void)?
        func fire() {
            let call = call
            self.call = nil
            call?()
        }
    }
    private let arrival = Arrival()
    /// When a hand-over must be done by, so a Shortcuts action finishes inside
    /// the time iOS gives it. Before 25 November 2026 one ran for 18 minutes in
    /// the car and Shortcuts said "an unknown error occurred".
    @MainActor final class Budget { var deadline: Date? }
    private let budget = Budget()
    /// Whether the Mac isn't connected to the relay, and why; nil while it is.
    /// Without it, Continue on iPhone plays the Mac's last song from where it
    /// stopped and asks the Mac nothing.
    var macAway: @MainActor () -> MacAway? = { nil }
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
    /// Where the widget's picture lives; tests pass their own.
    var widgetDefaults: UserDefaults = WidgetSnapshot.defaults

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
    /// `within` caps the whole hand-over, in seconds: waits shorten to fit,
    /// and steps that only add something (a station to follow) are dropped.
    public func continueOnPhone(with player: any PhoneMusicPlaying, timeout: TimeInterval = 10,
                                within: TimeInterval? = nil,
                                from source: HandoverSource = .unknown,
                                arrived: (@MainActor () -> Void)? = nil) async -> ContinueOutcome {
        arrival.call = arrived
        budget.deadline = within.map { now().addingTimeInterval($0) }
        defer {
            arrival.call = nil
            budget.deadline = nil
        }
        let started = now()
        let outcome = await performContinueOnPhone(with: player, timeout: timeout)
        // Every hand-over, with where it came from (23 November 2026: six ran in
        // three minutes, and nothing said who started them).
        LockScreenRecord.add("Continue on iPhone from \(source.rawValue): \(outcome) in \(Self.seconds(since: started, now: now()))",
                             at: now(), in: widgetDefaults)
        // The widget shows the song as on the iPhone, with Continue on Mac.
        switch outcome {
        case .continued, .macStillPlaying, .resumedHere, .alreadyPlayingHere, .continuedWithoutMac:
            WidgetSnapshot.markOnIPhone(true, in: widgetDefaults)
        case .unavailable, .notAllowed, .didNotStart: break
        }
        return outcome
    }

    static func seconds(since start: Date, now: Date) -> String {
        String(format: "%.1f s", now.timeIntervalSince(start))
    }

    /// `cap`, or less if the hand-over's time is running out. Never below
    /// `floor`, so a last step still gets a fair try.
    private func remaining(_ cap: TimeInterval, floor: TimeInterval = 0) -> TimeInterval {
        guard let deadline = budget.deadline else { return cap }
        return max(floor, min(cap, deadline.timeIntervalSince(now())))
    }

    /// Whether the hand-over has a time limit.
    private var isBudgeted: Bool { budget.deadline != nil }

    /// `work`'s answer, or nil once `seconds` pass. For a step that waits on
    /// the network and can't be told to stop; it carries on unseen.
    private static func answer<T: Sendable>(within seconds: TimeInterval, _ work: @escaping @MainActor () async -> T?) async -> T? {
        guard seconds > 0 else { return nil }
        return await withCheckedContinuation { continuation in
            let once = Once()
            Task { @MainActor in
                let value = await work()
                if once.claim() { continuation.resume(returning: value) }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                if once.claim() { continuation.resume(returning: nil) }
            }
        }
    }

    @MainActor private final class Once {
        private var claimed = false
        func claim() -> Bool {
            defer { claimed = true }
            return !claimed
        }
    }

    /// The Mac's next songs, with catalogue IDs found here for those the Mac
    /// has none for: it has them only for songs in its library. On 25
    /// November 2026 a Mac playing an Apple Music playlist had IDs for 9 of
    /// its 18 next songs, and the phone queued only those 9. The searches
    /// start with the hand-over and run while the Mac's playlist is tried.
    @MainActor final class UpNextLookup {
        private let upNext: [QueuedTrack]
        private var found: [Int: String] = [:]
        private var searches: Task<Void, Never>?
        /// How many songs it looks up.
        let asked: Int
        var foundCount: Int { found.count }

        init(_ upNext: [QueuedTrack], with player: any PhoneMusicPlaying) {
            self.upNext = upNext
            let missing = upNext.indices.filter { upNext[$0].catalogID == nil }
            asked = missing.count
            guard !missing.isEmpty else { return }
            let each = missing.map { index in
                let song = upNext[index]
                return Task { @MainActor [weak self] in
                    let candidates = await player.searchCatalog(title: song.title, artist: song.artist)
                    guard let id = CatalogCandidate.best(title: song.title, artist: song.artist, duration: song.duration,
                                                         in: candidates)?.id else { return }
                    self?.found[index] = id
                }
            }
            searches = Task { for search in each { await search.value } }
        }

        /// The next songs' catalogue IDs in order, once the searches end or
        /// `seconds` pass. A song not found by then is left out.
        func catalogIDs(within seconds: TimeInterval) async -> [String] {
            if let searches {
                _ = await Handover.answer(within: seconds) {
                    await searches.value
                    return true
                }
            }
            return upNext.indices.compactMap { upNext[$0].catalogID ?? found[$0] }
        }
    }

    /// How long the Mac's queue may wait for the next songs to be found here.
    /// A search took about a second on 25 November 2026.
    static let upNextLookupWait: TimeInterval = 3
    /// What a hand-over with a time limit keeps for the song to start.
    static let startReserve: TimeInterval = 4

    private func performContinueOnPhone(with player: any PhoneMusicPlaying, timeout: TimeInterval) async -> ContinueOutcome {
        guard let message = latest(), let track = message.track else { return .unavailable }
        let away = macAway()
        if let away { record("Continue on iPhone: the Mac isn't connected (\(away.rawValue)); its last song from where it stopped") }
        let found: String?
        if isBudgeted, track.catalogID == nil {
            found = await Self.answer(within: remaining(8)) { [self] in await catalogID(for: track, with: player) }
        } else {
            found = await catalogID(for: track, with: player)
        }
        guard let catalogID = found else {
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
        let upNext = UpNextLookup(Array((message.upNext ?? []).prefix(PlaybackMessage.upNextLimit)), with: player)
        let position: @MainActor () -> TimeInterval = { [latest, now] in
            let at: TimeInterval
            if let current = latest(), current.track?.catalogID == catalogID {
                at = current.elapsed(at: now())
            } else {
                at = message.elapsed(at: Date())
            }
            // A Mac that went away while playing has no newer state, and its
            // position runs on: past the song's end, start it from the top.
            return track.duration > 0 && at >= track.duration - 2 ? 0 : at
        }
        let wait = remaining(min(timeout, Self.playlistStartWait), floor: 2)
        // What the Mac plays from, itself, rather than the next 25 of its
        // songs (17 November 2026): a library playlist or album, in order or
        // shuffled; the whole library shuffled; or Apple Music outside the
        // library, found through recently played.
        if let place = message.playlist, place.isValid {
            if let played = await player.play(catalogID, in: place, position: position, timeout: wait) {
                memory.savePlaylist(played)
                memory.saveAlbum(nil)
                record("Continue on iPhone: the Mac's playlist plays here, from song \(played.index + 1) of \(played.count)\(played.isShuffled ? ", shuffled" : "")")
                return await finishContinuing(catalogID, songsAfter: played.isShuffled ? played.count - 1 : played.count - played.index - 1,
                                              from: "the playlist", repeatMode: message.repeatMode, with: player)
            }
            record("Continue on iPhone: the Mac's playlist isn't here with the song; its next songs instead")
        } else if let album = message.album, album.isValid {
            if let played = await player.play(catalogID, inAlbum: album, position: position, timeout: wait) {
                memory.savePlaylist(nil)
                memory.saveAlbum(played)
                record("Continue on iPhone: the Mac's album plays here, from song \(played.index + 1) of \(played.count)\(played.isShuffled ? ", shuffled" : "")")
                return await finishContinuing(catalogID, songsAfter: played.isShuffled ? played.count - 1 : played.count - played.index - 1,
                                              from: "the album", repeatMode: message.repeatMode, with: player)
            }
            record("Continue on iPhone: the Mac's album isn't here with the song; its next songs instead")
        } else if message.shuffledLibrary == true {
            if await player.playShuffledLibrary(from: catalogID, position: position, timeout: wait) {
                memory.savePlaylist(nil)
                memory.saveAlbum(nil)
                record("Continue on iPhone: the song plays here, then the library shuffled")
                return await finishContinuing(catalogID, songsAfter: Self.stationBelow, from: "the library", repeatMode: message.repeatMode,
                                              with: player)
            }
            record("Continue on iPhone: the song isn't in the library here; the Mac's next songs instead")
        } else if message.fromAppleMusic == true, away == nil {
            // Not without the Mac: recently played can take a minute to list
            // what the Mac played, and the Mac's Up Next is there already.
            // A station on the Mac lists one song ahead; a playlist or album,
            // more. And recently played names the station the Mac played
            // before for a while after it starts another.
            let settled = message.appleMusicSince.map { now().timeIntervalSince($0) >= Self.recentlyPlayedLag } ?? true
            let allowStation = (message.upNext?.count ?? 0) <= 1 && settled
            switch await player.playFromAppleMusic(catalogID, title: track.title, artist: track.artist, position: position,
                                                   timeout: remaining(wait + Self.recentlyPlayedAllowance, floor: 2),
                                                   shuffled: message.shuffled == true, allowStation: allowStation,
                                                   following: message.upNext ?? []) {
            case .playlist(let played)?:
                memory.savePlaylist(nil)
                memory.saveAlbum(nil)
                record("Continue on iPhone: the Mac's Apple Music playlist plays here, from song \(played.index + 1) of \(played.count)")
                return await finishContinuing(catalogID, songsAfter: played.isShuffled ? played.count - 1 : played.count - played.index - 1,
                                              from: "the playlist", repeatMode: message.repeatMode, with: player)
            case .album(let played, _)?:
                memory.savePlaylist(nil)
                memory.saveAlbum(nil)
                record("Continue on iPhone: the Mac's Apple Music album plays here, from song \(played.index + 1) of \(played.count)")
                return await finishContinuing(catalogID, songsAfter: played.isShuffled ? played.count - 1 : played.count - played.index - 1,
                                              from: "the album", repeatMode: message.repeatMode, with: player)
            case .station?:
                memory.savePlaylist(nil)
                memory.saveAlbum(nil)
                record("Continue on iPhone: the song plays here, then the Mac's station")
                return await finishContinuing(catalogID, songsAfter: Self.stationBelow, from: "the station", repeatMode: nil, with: player)
            case nil:
                record("Continue on iPhone: Apple Music doesn't list what the Mac plays from yet; its next songs instead")
            }
        }
        memory.savePlaylist(nil)
        memory.saveAlbum(nil)
        let next = await upNext.catalogIDs(within: max(0, remaining(Self.upNextLookupWait + Self.startReserve) - Self.startReserve))
        if upNext.asked > 0 {
            record("Continue on iPhone: found \(upNext.foundCount) of the \(upNext.asked) next songs the Mac has no catalogue ID for")
        }
        let queue = [catalogID] + next
        let started = await player.play(catalogIDs: queue, position: position, timeout: remaining(timeout, floor: 3))
        guard started else {
            record("Continue on iPhone: Apple Music didn't start \(message.track?.title ?? "the song")")
            return .didNotStart
        }
        memory.saveQueued(Array(queue))
        return await finishContinuing(catalogID, songsAfter: queue.count - 1, from: "the Mac", repeatMode: message.repeatMode, with: player)
    }

    /// How much longer Apple Music's recently played may take to answer.
    static let recentlyPlayedAllowance: TimeInterval = 3
    /// How long recently played may take to list what the Mac started: 25–40
    /// s for a station on 17 November 2026.
    static let recentlyPlayedLag: TimeInterval = 60

    /// Once the song plays here: repeat as on the Mac, the Mac paused, and a
    /// station from the song when few songs are left to play.
    private func finishContinuing(_ catalogID: String, songsAfter: Int, from source: String, repeatMode: RepeatMode?,
                                  with player: any PhoneMusicPlaying) async -> ContinueOutcome {
        // The song plays here now: that's the moment the music moved.
        arrival.fire()
        if source != "the Mac" { memory.saveQueued(nil) }
        if let repeatMode { player.setRepeat(repeatMode) }
        let outcome = await pauseMac(for: catalogID, songsAfter: songsAfter)
        if songsAfter < Self.stationBelow, repeatMode != .all, repeatMode != .one {
            if isBudgeted {
                // Only adds to what plays later: skipped when time is short.
                let left = remaining(6)
                if left >= 1 {
                    let added: Bool? = await Self.answer(within: left) { [self] in
                        await followWithStation(seededBy: catalogID, songsAfter: songsAfter, from: source, with: player)
                        return true
                    }
                    if added == nil { record("Continue on iPhone: no time left to add a station") }
                }
            } else {
                await followWithStation(seededBy: catalogID, songsAfter: songsAfter, from: source, with: player)
            }
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
        // Nothing to pause: the Mac isn't there. Its music stopped when it
        // went to sleep, or it's gone; it learns nothing, and plays nothing.
        if let away = macAway() {
            remember(catalogID)
            record("Continue on iPhone: playing here; the Mac isn't connected (\(away.rawValue)), so it wasn't asked to pause")
            return .continuedWithoutMac(away)
        }
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
            if attempt == 1 {
                guard remaining(3) >= 3 else { break }
                try? await sleep(1)
            }
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
    public func sendBackToMac(with player: any PhoneMusicPlaying, timeout: TimeInterval = 10,
                              from source: HandoverSource = .unknown,
                              arrived: (@MainActor () -> Void)? = nil) async -> SendBackOutcome {
        arrival.call = arrived
        defer { arrival.call = nil }
        let started = now()
        let outcome = await performSendBackToMac(with: player, timeout: timeout)
        LockScreenRecord.add("Continue on Mac from \(source.rawValue): \(outcome) in \(Self.seconds(since: started, now: now()))",
                             at: now(), in: widgetDefaults)
        if outcome == .sentBack || outcome == .sentAsStation { WidgetSnapshot.markOnIPhone(false, in: widgetDefaults) }
        return outcome
    }

    private func performSendBackToMac(with player: any PhoneMusicPlaying, timeout: TimeInterval) async -> SendBackOutcome {
        // Playing or paused here: a paused song is still the phone's to hand on.
        guard let here = player.nowPlaying(), let catalogID = here.catalogID else { return .nothingPlayingHere }
        let ahead = macQueuePosition(of: catalogID)
        // A song from the Mac's Up Next that Continue on iPhone queued here
        // comes from no playlist, album or station: don't look for one.
        let fromMacUpNext = memory.loadQueued()?.contains(catalogID) == true
        var place = fromMacUpNext ? nil : await player.playlistPlace(remembered: memory.loadPlaylist())
        // Not from a playlist: perhaps an album (17 November 2026).
        var album = place == nil && !fromMacUpNext ? await player.albumPlace(remembered: memory.loadAlbum()) : nil
        // Neither in the library: Apple Music's own, or the library shuffled.
        let lookFurther = place == nil && album == nil && !fromMacUpNext
        let appleMusic = lookFurther ? await player.appleMusicSource() : nil
        let shuffledLibrary = lookFurther && appleMusic == nil ? await player.isShufflingLibrary() : false
        if fromMacUpNext { record("Send back to Mac: the song is from the Mac's Up Next, queued here by Continue on iPhone") }
        // The Mac's own queue when it's the phone's source (the round trip)
        // or the phone has none; else the phone's, even for a song the Mac
        // has, as when the Mac plays the song's station.
        let mac = latest()
        let sameAsTheMac: Bool
        if let place {
            sameAsTheMac = mac?.playlist?.name == place.name
        } else if let album {
            sameAsTheMac = mac?.track?.album == album.title || mac?.album?.title == album.title
        } else if appleMusic != nil {
            sameAsTheMac = mac?.fromAppleMusic == true
        } else if shuffledLibrary {
            sameAsTheMac = mac?.shuffledLibrary == true
        } else {
            sameAsTheMac = true
        }
        let hasSource = place != nil || album != nil || appleMusic != nil || shuffledLibrary
        if let ahead, !hasSource || (ahead <= Self.skipsAtMost && sameAsTheMac) {
            return await skipMacAhead(ahead, to: catalogID, here: here, with: player, timeout: timeout)
        }
        var station: StationPlace?
        var allowance = Self.stationStartAllowance
        switch appleMusic {
        case .playlist(var online)?:
            if memory.addsToLibrary(), await player.addToLibrary(.playlist(online)) {
                online.addedToLibrary = true
                place = online
                allowance += PlaylistPlace.librarySyncWait
                record("Send back to Mac: the phone's Apple Music playlist, added to the library, from song \(online.index + 1) of \(online.count)")
            } else {
                record("Send back to Mac: the phone's Apple Music playlist isn't in the library; the song's station instead")
            }
        case .album(var online, let id)?:
            if memory.addsToLibrary(), await player.addToLibrary(.album(online, id: id)) {
                online.addedToLibrary = true
                album = online
                allowance += PlaylistPlace.librarySyncWait
                record("Send back to Mac: the phone's Apple Music album, added to the library, from song \(online.index + 1) of \(online.count)")
            } else {
                record("Send back to Mac: the phone's Apple Music album isn't in the library; the song's station instead")
            }
        case .station(let found)?:
            station = found
            record("Send back to Mac: the phone's station, which starts on another song on the Mac")
        case nil:
            if let place {
                record("Send back to Mac: the phone's playlist, from song \(place.index + 1) of \(place.count)\(place.isShuffled ? ", shuffled" : "")")
            } else if let album {
                record("Send back to Mac: the phone's album, from song \(album.index + 1) of \(album.count)\(album.isShuffled ? ", shuffled here; in order on the Mac" : "")")
            } else if shuffledLibrary {
                record("Send back to Mac: the song, then the library shuffled")
            }
        }
        return await sendAsStation(here, catalogID: catalogID, playlist: place, album: album, station: station,
                                   shuffledLibrary: shuffledLibrary ? true : nil, repeatMode: player.repeatMode(), with: player,
                                   timeout: timeout + allowance)
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
                arrival.fire()
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
                               station: StationPlace? = nil, shuffledLibrary: Bool? = nil, repeatMode: RepeatMode? = nil,
                               with player: any PhoneMusicPlaying, timeout: TimeInterval) async -> SendBackOutcome {
        let before = latest()
        // Where the phone is and the song's title, so the Mac can seek itself
        // the moment Music starts the song (16 November 2026).
        let nowPlaying = player.nowPlaying()
        let position = nowPlaying?.position ?? here.position
        // A paused phone isn't moving on, so the Mac mustn't add the time
        // since `issuedAt` (it overshot to 10 s instead of 6.5 s in the 19
        // November 2026 soak test).
        let paused = (nowPlaying?.isPlaying ?? here.isPlaying) == false
        guard await step(.playStation(seededBy: catalogID, position: position, title: here.title, playlist: playlist, album: album,
                                      station: station, shuffledLibrary: shuffledLibrary, repeatMode: repeatMode,
                                      positionIsPaused: paused ? true : nil, issuedAt: now())) else {
            return .macRefused
        }
        let deadline = now().addingTimeInterval(timeout)
        while now() < deadline {
            await refresh()
            if let current = latest(), current.state == .playing, let track = current.track,
               current.revision > (before?.revision ?? 0), track.id != before?.track?.id || track.catalogID == catalogID {
                arrival.fire()
                let sameSong = track.catalogID == catalogID
                    || (track.catalogID == nil && here.title.map { track.title.caseInsensitiveCompare($0) == .orderedSame } == true)
                if sameSong { await seekIfTheMacMissedIt(player: player, here: here) }
                if player.nowPlaying()?.isPlaying == true { player.pause() }
                memory.save(nil)
                let what = playlist != nil ? "the song's playlist (or its station)" : album != nil ? "the song's album (or its station)"
                    : station != nil ? "the phone's station" : shuffledLibrary == true ? "the library, shuffled (or the song's station)" : "the song's station"
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
        // Six looks, 3 s: the Mac now says where it is straight after its seek.
        for attempt in 0..<6 {
            if let gap = gap(), gap <= Self.seekTolerance { return }
            if attempt < 5 {
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
