#if DEBUG
import MediaPlayer
import MusicKit
import StandByKit

/// Development builds only (17 November 2026): hand-overs with playlists,
/// tried on a phone without tapping.
///
///     xcrun devicectl device process launch --console --device <udid> --terminate-existing \
///         com.alistairmerritt.MusicStandBy -- <switches>
///
/// - `-playlistProbe NAME SONG SECONDS [shuffle]`: plays the library playlist
///   from that song (from 1), skips once, and prints Music's queue place and
///   Apple Music's recently played, as a person starting a playlist would.
/// - `-continueOnPhone`, `-continueOnMac`: the app's own Continue on iPhone or
///   Continue on Mac, printing the outcome and the app's log, timed.
/// - `-playlistProbePause`: pauses Apple Music here.
///
/// Each prints lines starting "PPROBE", then quits the app so `devicectl`
/// returns. They play sound on the phone.
@MainActor
enum HandoverProbe {
    private static func say(_ text: String) { print("PPROBE \(text)") }

    /// Continue on iPhone or Continue on Mac without a tap, through the same
    /// call the app's buttons make, printing the outcome and the app's log:
    /// `-continueOnPhone`, `-continueOnMac`.
    static func runHandoverIfAsked(model: AppModel) {
        let arguments = ProcessInfo.processInfo.arguments
        let toPhone = arguments.contains("-continueOnPhone"), toMac = arguments.contains("-continueOnMac")
        guard toPhone || toMac else { return }
        Task {
            let started = Date()
            while !model.canContinueOnPhone, Date().timeIntervalSince(started) < 20 { try? await Task.sleep(for: .milliseconds(200)) }
            say("Mac state after \(Int(Date().timeIntervalSince(started) * 1000)) ms: \(model.canContinueOnPhone ? "ready" : "not ready")")
            let before = model.log.first?.id
            let player = SystemMusicPhonePlayer()
            let t0 = Date()
            if toPhone {
                let outcome = await model.continueOnPhone(with: player)
                say("continueOnPhone: \(outcome) in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
            } else {
                let outcome = await model.sendBackToMac(with: player)
                say("sendBackToMac: \(outcome) in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
            }
            // Newest first: everything above the entry that was first before.
            for entry in model.log.prefix(while: { $0.id != before }).reversed() {
                say("log +\(Int(entry.date.timeIntervalSince(t0) * 1000)) ms: \(entry.message)")
            }
            let mp = MPMusicPlayerController.systemMusicPlayer
            say("phone now: state \(mp.playbackState.rawValue), index \(mp.indexOfNowPlayingItem), shuffle \(mp.shuffleMode.rawValue), at \(Int(mp.currentPlaybackTime)) s, \(describe(mp.nowPlayingItem))")
            finish()
        }
    }

    /// `-albumProbe TITLE SONG SECONDS [shuffle]`: plays the library album
    /// with that title from that song (from 1, by disc, then track), as a
    /// person tapping a song in the album would.
    static func runAlbumIfAsked() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let at = arguments.firstIndex(of: "-albumProbe"), arguments.count > at + 3,
              let number = Int(arguments[at + 2]), let seconds = Double(arguments[at + 3]) else { return }
        let title = arguments[at + 1]
        let shuffle = arguments.count > at + 4 && arguments[at + 4] == "shuffle"
        Task {
            let query = MPMediaQuery.songs()
            query.addFilterPredicate(MPMediaPropertyPredicate(value: title, forProperty: MPMediaItemPropertyAlbumTitle))
            let songs = (query.items ?? []).sorted { ($0.discNumber, $0.albumTrackNumber) < ($1.discNumber, $1.albumTrackNumber) }
            say("album: \(songs.count) songs titled \(title)")
            guard number >= 1, number <= songs.count else { return finish() }
            let player = MPMusicPlayerController.systemMusicPlayer
            player.shuffleMode = .off
            player.setQueue(with: MPMediaItemCollection(items: songs))
            player.nowPlayingItem = songs[number - 1]
            try? await player.prepareToPlay()
            player.currentPlaybackTime = seconds
            player.play()
            if shuffle {
                try? await Task.sleep(for: .seconds(1))
                player.shuffleMode = .songs
            }
            try? await Task.sleep(for: .seconds(2))
            let now = player.nowPlayingItem
            say("playing: index \(player.indexOfNowPlayingItem), disc \(now?.discNumber ?? 0) track \(now?.albumTrackNumber ?? 0), shuffle \(player.shuffleMode.rawValue), \(describe(now))")
            finish()
        }
    }

    /// `-libraryShuffleProbe`: the whole library, shuffled, from the song
    /// Apple Music here is on (or the first library song). `-catalogPlaylistProbe
    /// TERM SONG`: an Apple Music playlist found by search, from that song (from
    /// 1), through MusicKit's system player.
    static func runQueueProbesIfAsked() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-libraryShuffleProbe") {
            Task {
                let player = MPMusicPlayerController.systemMusicPlayer
                let songs = MPMediaQuery.songs().items ?? []
                guard let item = player.nowPlayingItem ?? songs.first else { return finish() }
                say("library: \(songs.count) songs; starting from \(describe(item))")
                player.shuffleMode = .off
                player.setQueue(with: MPMediaQuery.songs())
                player.nowPlayingItem = item
                try? await player.prepareToPlay()
                player.play()
                try? await Task.sleep(for: .seconds(1.5))
                say("playing: \(player.nowPlayingItem?.persistentID == item.persistentID ? "the same song" : "ANOTHER song"), index \(player.indexOfNowPlayingItem)")
                player.shuffleMode = .songs
                try? await Task.sleep(for: .seconds(1.5))
                say("shuffle on: \(player.nowPlayingItem?.persistentID == item.persistentID ? "still the same song" : "ANOTHER song"), state \(player.playbackState.rawValue)")
                for _ in 0..<2 {
                    player.skipToNextItem()
                    try? await Task.sleep(for: .seconds(2))
                    say("next: \(describe(player.nowPlayingItem)) from album \(player.nowPlayingItem?.albumTitle ?? "?")")
                }
                finish()
            }
        }
        if let at = arguments.firstIndex(of: "-libraryAddProbe"), arguments.count > at + 1 {
            // Adds an Apple Music playlist found by search to the library (the person agreed).
            let term = arguments[at + 1]
            Task {
                do {
                    var search = MusicCatalogSearchRequest(term: term, types: [Playlist.self])
                    search.limit = 3
                    guard let found = try await search.response().playlists.first else { say("no playlist for \(term)"); return finish() }
                    let started = Date()
                    try await MusicLibrary.shared.add(found)
                    say("added \(found.name) [\(found.id)] to the library in \(Int(Date().timeIntervalSince(started) * 1000)) ms at \(Date())")
                } catch {
                    say("add failed: \(error)")
                }
                finish()
            }
        }
        if let at = arguments.firstIndex(of: "-catalogPlaylistProbe"), arguments.count > at + 2, let number = Int(arguments[at + 2]) {
            let term = arguments[at + 1]
            Task {
                do {
                    var search = MusicCatalogSearchRequest(term: term, types: [Playlist.self])
                    search.limit = 3
                    guard let found = try await search.response().playlists.first else { say("no playlist for \(term)"); return finish() }
                    let playlist = try await found.with([.entries])
                    let tracks = Array(playlist.entries ?? [])
                    say("playlist \(playlist.name) [\(playlist.id)]: \(tracks.count) songs")
                    guard number >= 1, number <= tracks.count else { return finish() }
                    let target = tracks[number - 1]
                    let player = SystemMusicPlayer.shared
                    player.queue = SystemMusicPlayer.Queue(playlist: playlist, startingAt: target)
                    try await player.play()
                    try? await Task.sleep(for: .seconds(2.5))
                    say("target: \(target.title); playing: \(player.queue.currentEntry?.title ?? "nil"), status \(player.state.playbackStatus)")
                    try await player.skipToNextEntry()
                    try? await Task.sleep(for: .seconds(2.5))
                    say("expected next: \(number < tracks.count ? tracks[number].title : "-"); now: \(player.queue.currentEntry?.title ?? "nil")")
                } catch {
                    say("failed: \(error)")
                }
                finish()
            }
        }
    }

    static func runIfAsked() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-playlistProbePause") {
            MPMusicPlayerController.systemMusicPlayer.pause()
            say("paused")
            finish()
            return
        }
        guard let at = arguments.firstIndex(of: "-playlistProbe"), arguments.count > at + 3,
              let index = Int(arguments[at + 2]), let seconds = Double(arguments[at + 3]) else { return }
        let name = arguments[at + 1]
        let shuffle = arguments.count > at + 4 && arguments[at + 4] == "shuffle"
        Task { await run(name: name, index: index, seconds: seconds, shuffle: shuffle) }
    }

    private static func run(name: String, index: Int, seconds: Double, shuffle: Bool) async {
        let player = MPMusicPlayerController.systemMusicPlayer
        let started = Date()
        let playlists = (MPMediaQuery.playlists().collections ?? []).compactMap { $0 as? MPMediaPlaylist }
        let named = playlists.filter { $0.name == name }
        say("library: \(playlists.count) playlists, \(named.count) named \(name) in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        guard let playlist = named.first, index >= 1, index <= playlist.items.count else { return say("not found") }
        let item = playlist.items[index - 1]
        say("playlist: \(playlist.count) songs, persistent \(playlist.persistentID), cloud \(playlist.cloudGlobalID ?? "nil"), attributes \(playlist.playlistAttributes.rawValue)")
        say("target \(index): \(describe(item)); next \(index < playlist.items.count ? describe(playlist.items[index]) : "-")")

        player.shuffleMode = shuffle ? .songs : .off
        player.setQueue(with: playlist)
        player.nowPlayingItem = item
        do { try await player.prepareToPlay() } catch { say("prepare failed: \(error)") }
        player.currentPlaybackTime = seconds
        player.play()
        let t0 = Date()
        while Date().timeIntervalSince(t0) < 8, !(player.playbackState == .playing && player.nowPlayingItem?.persistentID == item.persistentID) {
            try? await Task.sleep(for: .milliseconds(150))
        }
        say("playing after \(Int(Date().timeIntervalSince(t0) * 1000)) ms: state \(player.playbackState.rawValue), index \(player.indexOfNowPlayingItem), at \(Int(player.currentPlaybackTime)) s, now \(describe(player.nowPlayingItem))")
        if abs(player.currentPlaybackTime - seconds) > 2 { player.currentPlaybackTime = seconds; say("re-seeked") }
        try? await Task.sleep(for: .seconds(2))
        say("after 2 s: at \(Int(player.currentPlaybackTime)) s")

        player.skipToNextItem()
        try? await Task.sleep(for: .seconds(2.5))
        say("after skip: index \(player.indexOfNowPlayingItem), now \(describe(player.nowPlayingItem))")

        do {
            var request = MusicRecentlyPlayedContainerRequest()
            request.limit = 3
            for (i, container) in try await request.response().items.enumerated() {
                switch container {
                case .playlist(let p): say("recent \(i): playlist \(p.name) [\(p.id)]")
                case .album(let a): say("recent \(i): album \(a.title) [\(a.id)]")
                case .station(let s): say("recent \(i): station \(s.name) [\(s.id)]")
                @unknown default: say("recent \(i): other")
                }
            }
        } catch { say("recent failed: \(error)") }
        finish()
    }

    /// Ends the development run, so `devicectl --console` returns at once.
    private static func finish() {
        say("done")
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            exit(0)
        }
    }

    private static func describe(_ item: MPMediaItem?) -> String {
        guard let item else { return "nil" }
        return "\(item.title ?? "?") — \(item.artist ?? "?") [store \(item.playbackStoreID), persistent \(item.persistentID)]"
    }
}
#endif
