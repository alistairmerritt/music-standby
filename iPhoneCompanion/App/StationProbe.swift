#if DEBUG
import MediaPlayer
import MusicKit
import os
import StandByKit

/// Development builds only: how Apple Music here takes a station after a
/// queue, tried from the Mac without anyone at the phone (15 November 2026).
///
///     xcrun devicectl device process launch --device <udid> --terminate-existing \
///         com.alistairmerritt.MusicStandBy -stationProbe
///
/// Loads the Mac's song and Up Next (from the relay) into Apple Music here,
/// adds the song's station three ways in turn, and skips through each queue
/// while paused, logging every song that comes (`StationProbe` category). It
/// never plays, and pauses after every skip. It replaces Apple Music's queue here.
@MainActor
enum StationProbe {
    private static let log = Logger(subsystem: "com.alistairmerritt.MusicStandBy", category: "StationProbe")

    static func runIfAsked(model: AppModel) {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-stationProbe") { Task { await run() } }
        if arguments.contains("-stationProbePlaying") { Task { await runPlaying() } }
        // Stop Showing and Show in Now Playing from the Mac, so a test build
        // can go on without anyone tapping: installing over a live session
        // leaves the extension running from the old build (16 November 2026).
        if arguments.contains("-stopShowing") {
            Task { await model.stopNowPlaying(); say("stopped showing") }
        }
        if arguments.contains("-showNowPlaying") {
            Task {
                try? await Task.sleep(for: .seconds(2))
                await model.activateNowPlaying()
                say("showing")
            }
        }
    }

    /// The same queues, playing: a station loads its next songs only as it
    /// plays, so a paused walk can't tell a station from two of its songs.
    /// Makes sound on the phone, about a second at each skip.
    private static func runPlaying() async {
        try? await Task.sleep(for: .seconds(2))
        guard let (seed, upNext, station) = await macSongAndStation() else { return }
        let player = MPMusicPlayerController.systemMusicPlayer

        // A, as built, playing.
        player.stop()
        say("A: setting the queue")
        player.setQueue(with: [seed] + upNext)
        say("A: preparing")
        say("A: prepared? \(await prepareAtMost(player, seconds: 8))")
        say("A: inserting the station")
        let inserted = await atMost(seconds: 8) {
            do {
                try await SystemMusicPlayer.shared.queue.insert(station, position: .tail)
                return "accepted"
            } catch {
                return "refused: \(error)"
            }
        }
        say("A: insert \(inserted ?? "didn't answer in 8 s")")
        player.play()
        try? await Task.sleep(for: .seconds(1))
        say("A playing 0: \(describe(player.nowPlayingItem))")
        // To the station's first song, then let it play a moment so it can load more.
        await skipPlaying("A", player, count: upNext.count + 1, from: 1)
        try? await Task.sleep(for: .seconds(4))
        await skipPlaying("A", player, count: 8, from: upNext.count + 2)

        // C, the station alone, playing: the comparison.
        do {
            SystemMusicPlayer.shared.queue = [station]
            try await SystemMusicPlayer.shared.play()
        } catch {
            say("C: refused: \(error)")
        }
        try? await Task.sleep(for: .seconds(3))
        say("C playing 0: \(describe(player.nowPlayingItem))")
        await skipPlaying("C", player, count: 8, from: 1)

        player.pause()
        say("done playing")
    }

    /// Nil when `operation` hasn't answered in time.
    private static func atMost(seconds: Double, _ operation: @escaping @MainActor () async -> String) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask { await operation() }
            group.addTask { try? await Task.sleep(for: .seconds(seconds)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private static func prepareAtMost(_ player: MPMusicPlayerController, seconds: Double) async -> String {
        await atMost(seconds: seconds) {
            await withCheckedContinuation { continuation in
                player.prepareToPlay { error in continuation.resume(returning: error.map { "error \($0)" } ?? "yes") }
            }
        } ?? "no answer in \(Int(seconds)) s"
    }

    private static func skipPlaying(_ label: String, _ player: MPMusicPlayerController, count: Int, from first: Int) async {
        for step in first..<(first + count) {
            let before = player.nowPlayingItem?.playbackStoreID
            player.skipToNextItem()
            var changed = false
            for _ in 0..<25 {
                try? await Task.sleep(for: .milliseconds(200))
                if player.nowPlayingItem?.playbackStoreID != before { changed = true; break }
            }
            if changed { try? await Task.sleep(for: .milliseconds(800)) }
            say("\(label) playing \(step): \(describe(player.nowPlayingItem)), state \(player.playbackState.rawValue)")
            if !changed || player.nowPlayingItem == nil { return say("\(label): the queue ended") }
        }
    }

    private static func macSongAndStation() async -> (String, [String], Station)? {
        do {
            let remote = try MacRemote.paired(credentials: KeychainCredentialStore())
            guard let message = try await remote.read().playback, let seed = message.track?.catalogID else {
                say("no Mac song with a catalogue ID")
                return nil
            }
            var request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(seed))
            request.properties = [.station]
            guard let station = try await request.response().items.first?.station else {
                say("Apple Music has no station for the song")
                return nil
            }
            let upNext = (message.upNext ?? []).compactMap(\.catalogID)
            say("Mac: \(seed) '\(message.track?.title ?? "")', Up Next \(upNext.count); station \(station.id.rawValue)")
            return (seed, upNext, station)
        } catch {
            say("setup: \(error)")
            return nil
        }
    }

    private static func say(_ text: String) { log.log("PROBE \(text, privacy: .public)") }

    private static func run() async {
        try? await Task.sleep(for: .seconds(2))
        say("start; MusicKit \(MusicAuthorization.currentStatus)")
        let message: PlaybackMessage
        do {
            let remote = try MacRemote.paired(credentials: KeychainCredentialStore())
            guard let playback = try await remote.read().playback else { return say("the relay has no state") }
            message = playback
        } catch {
            return say("relay: \(error)")
        }
        guard let seed = message.track?.catalogID else { return say("the Mac's song has no catalogue ID") }
        let upNext = (message.upNext ?? []).compactMap(\.catalogID)
        say("Mac: \(seed) '\(message.track?.title ?? "")', Up Next \(upNext.count) with an ID")

        let station: Station
        do {
            var request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(seed))
            request.properties = [.station]
            guard let found = try await request.response().items.first?.station else { return say("Apple Music has no station for the song") }
            station = found
            say("station \(found.id.rawValue) '\(found.name)'")
        } catch {
            return say("catalogue: \(error)")
        }

        let player = MPMusicPlayerController.systemMusicPlayer
        player.pause()

        // A, as built: MediaPlayer's queue, then MusicKit's insert at the tail.
        player.setQueue(with: [seed] + upNext)
        await prepare(player)
        do {
            try await SystemMusicPlayer.shared.queue.insert(station, position: .tail)
            say("A: MusicKit insert accepted")
        } catch {
            say("A: MusicKit insert refused: \(error)")
        }
        await walk("A", player, steps: 10)

        // B: MediaPlayer's queue, then MediaPlayer's append by store ID.
        player.setQueue(with: [seed] + upNext)
        await prepare(player)
        player.append(MPMusicPlayerStoreQueueDescriptor(storeIDs: [station.id.rawValue]))
        await walk("B", player, steps: 10)

        // C: the station alone. Does it start with the song it's made from?
        do {
            SystemMusicPlayer.shared.queue = [station]
            try await SystemMusicPlayer.shared.prepareToPlay()
            SystemMusicPlayer.shared.pause()
            say("C: starts with the song? \(player.nowPlayingItem?.playbackStoreID == seed)")
        } catch {
            say("C: refused: \(error)")
        }
        await walk("C", player, steps: 6)

        player.pause()
        say("done")
    }

    private static func prepare(_ player: MPMusicPlayerController) async {
        await withCheckedContinuation { continuation in player.prepareToPlay { _ in continuation.resume() } }
        player.pause()
    }

    /// Skips through the queue while paused, up to `steps` songs on.
    private static func walk(_ label: String, _ player: MPMusicPlayerController, steps: Int) async {
        say("\(label) 0: \(describe(player.nowPlayingItem))")
        for step in 1...steps {
            let before = player.nowPlayingItem?.playbackStoreID
            player.skipToNextItem()
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(200))
                if player.playbackState == .playing { player.pause() }
                if player.nowPlayingItem?.playbackStoreID != before { break }
            }
            if player.playbackState == .playing { player.pause() }
            say("\(label) \(step): \(describe(player.nowPlayingItem))")
            if player.nowPlayingItem == nil || player.nowPlayingItem?.playbackStoreID == before { break }
        }
    }

    private static func describe(_ item: MPMediaItem?) -> String {
        guard let item else { return "nothing (end of the queue)" }
        return "\(item.playbackStoreID) '\(item.title ?? "?")' — \(item.artist ?? "?")"
    }
}
#endif
