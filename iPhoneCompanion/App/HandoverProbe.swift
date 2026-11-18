#if DEBUG
import MediaPlayer
import MusicKit
import NowPlaying
import UIKit
import AVFoundation
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
        if arguments.contains("-primaryProbe") {
            // What the Lock Screen status reads: the app's session and every
            // session iOS has, each with isSystemPrimary, over a few seconds after
            // opening as normal.
            Task {
                let controller = model.sessionController as? RemoteSessionController
                for second in [1, 3, 6, 10] {
                    try? await Task.sleep(for: .seconds(second == 1 ? 1 : second == 3 ? 2 : second == 6 ? 3 : 4))
                    let sessions = (try? await RemoteMediaSession<MacPlaybackAttributes>.sessions()) ?? []
                    let all = sessions.map { "\($0.id.prefix(8)) primary \($0.isSystemPrimary)" }.joined(separator: "; ")
                    say("+\(second) s: app's session \(controller?.sessionID?.prefix(8) ?? "none") primary \(controller?.isSystemPrimary ?? false), error \(controller?.lastPrimaryError ?? "none"); iOS has \(sessions.count): \(all)")
                }
                finish()
            }
            return
        }
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
        // Any probe, and -stayAwake: the phone doesn't auto-lock while it runs,
        // so a long test can go on launching it (19 November 2026).
        if arguments.contains(where: { $0.hasSuffix("Probe") || $0.hasPrefix("-continueOn") || $0 == "-stayAwake" || $0 == "-phoneState" || $0 == "-phoneSkip" }) {
            UIApplication.shared.isIdleTimerDisabled = true
        }
        if arguments.contains("-phoneState") {
            // One line: song, store ID, playing, position, shuffle, repeat, queue index.
            let player = MPMusicPlayerController.systemMusicPlayer
            let item = player.nowPlayingItem
            say("state|\(item?.title ?? "-")|\(item?.playbackStoreID ?? "-")|\(player.playbackState == .playing ? "playing" : "not playing")|\(String(format: "%.1f", player.currentPlaybackTime))|shuffle \(player.shuffleMode.rawValue)|repeat \(player.repeatMode.rawValue)|index \(player.indexOfNowPlayingItem)")
            finish()
            return
        }
        if let at = arguments.firstIndex(of: "-phoneSkip"), arguments.count > at + 1, let count = Int(arguments[at + 1]) {
            // Skips Apple Music here on by COUNT songs, as listening on would.
            Task {
                let player = MPMusicPlayerController.systemMusicPlayer
                for _ in 0..<count {
                    player.skipToNextItem()
                    try? await Task.sleep(for: .milliseconds(800))
                }
                try? await Task.sleep(for: .seconds(1))
                say("skipped \(count): \(describe(player.nowPlayingItem)), \(player.playbackState == .playing ? "playing" : "not playing")")
                finish()
            }
            return
        }
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
        if let at = arguments.firstIndex(of: "-timingProbe"), arguments.count > at + 1 {
            // Times the library steps Continue on iPhone takes for an album.
            let id = arguments[at + 1]
            Task {
                var t = Date()
                @MainActor func lap(_ what: String) { say("\(what): \(Int(Date().timeIntervalSince(t) * 1000)) ms"); t = Date() }
                let all = MPMediaQuery.songs().items ?? []
                lap("all \(all.count) library songs")
                let item = all.first { $0.playbackStoreID == id }
                lap("found by store ID: \(item != nil)")
                guard let item else { return finish() }
                let album = MPMediaQuery.songs()
                album.addFilterPredicate(MPMediaPropertyPredicate(value: NSNumber(value: item.albumPersistentID), forProperty: MPMediaItemPropertyAlbumPersistentID))
                let songs = album.items ?? []
                lap("album: \(songs.count) songs")
                let player = MPMusicPlayerController.systemMusicPlayer
                player.shuffleMode = .off
                player.setQueue(with: MPMediaItemCollection(items: songs))
                player.nowPlayingItem = item
                lap("queue set")
                try? await player.prepareToPlay()
                lap("prepared")
                player.play()
                while !(player.playbackState == .playing && player.nowPlayingItem?.persistentID == item.persistentID) {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                lap("playing")
                player.pause()
                finish()
            }
            return
        }
        if let at = arguments.firstIndex(of: "-mediaVolume"), arguments.count > at + 1 {
            // Reads the media volume, and sets it unless the argument is "read":
            // MPVolumeView's slider, the only way, with the app in front.
            let wanted = Float(arguments[at + 1])
            Task { @MainActor in
                let session = AVAudioSession.sharedInstance()
                try? session.setCategory(.ambient, options: [.mixWithOthers])
                try? session.setActive(true)
                try? await Task.sleep(for: .milliseconds(500))
                say("volume was \(session.outputVolume)")
                if let wanted {
                    let view = MPVolumeView(frame: CGRect(x: -200, y: -200, width: 100, height: 40))
                    let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
                    window?.addSubview(view)
                    try? await Task.sleep(for: .milliseconds(500))
                    if let slider = view.subviews.compactMap({ $0 as? UISlider }).first {
                        slider.value = wanted
                        slider.sendActions(for: .valueChanged)
                    } else {
                        say("no slider")
                    }
                    try? await Task.sleep(for: .seconds(1))
                    say("volume now \(session.outputVolume)")
                }
                finish()
            }
            return
        }
        if let at = arguments.firstIndex(of: "-findAppleMusic"), arguments.count > at + 1 {
            // Continue on iPhone's recently played lookup for this song, without playing.
            let id = arguments[at + 1]
            Task {
                let t = Date()
                switch await SystemMusicPhonePlayer().findInRecentlyPlayed(id, allowStation: true) {
                case .playlist(let playlist, let entries, let index)?: say("playlist \(playlist.name) [\(playlist.id)]: song \(index + 1) of \(entries.count)")
                case .album(let album, let tracks, let index)?: say("album \(album.title) [\(album.id)]: song \(index + 1) of \(tracks.count)")
                case .station(let station)?: say("station \(station.name) [\(station.id)]")
                case nil: say("nothing with the song")
                }
                say("in \(Int(Date().timeIntervalSince(t) * 1000)) ms")
                finish()
            }
            return
        }
        if let at = arguments.firstIndex(of: "-loadSilently"), arguments.count > at + 2 {
            // Loads Apple Music here without playing: `library CATID [shuffle]`
            // or `station CATID` (that song's station), paused 30 s in.
            let mode = arguments[at + 1], id = arguments[at + 2]
            let shuffle = arguments.count > at + 3 && arguments[at + 3] == "shuffle"
            Task {
                let player = MPMusicPlayerController.systemMusicPlayer
                player.pause()
                player.shuffleMode = .off
                if mode == "library" {
                    guard let item = (MPMediaQuery.songs().items ?? []).first(where: { $0.playbackStoreID == id }) else { say("not in the library"); return finish() }
                    player.setQueue(with: MPMediaQuery.songs())
                    player.nowPlayingItem = item
                    try? await player.prepareToPlay()
                } else {
                    var request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(id))
                    request.properties = [.station]
                    guard let station = try? await request.response().items.first?.station else { say("no station"); return finish() }
                    SystemMusicPlayer.shared.queue = SystemMusicPlayer.Queue(for: [station])
                    try? await SystemMusicPlayer.shared.prepareToPlay()
                }
                player.currentPlaybackTime = 30
                if shuffle { player.shuffleMode = .songs }
                try? await Task.sleep(for: .seconds(1))
                say("loaded, \(player.playbackState == .playing ? "PLAYING" : "not playing"): \(describe(player.nowPlayingItem)); shuffle \(player.shuffleMode.rawValue), at \(Int(player.currentPlaybackTime)) s")
                if player.playbackState == .playing { player.pause() }
                finish()
            }
            return
        }
        if arguments.contains("-sourceProbe") {
            // What Continue on Mac would find here, without sending anything.
            Task {
                let phone = SystemMusicPhonePlayer()
                let player = MPMusicPlayerController.systemMusicPlayer
                say("now: \(describe(player.nowPlayingItem)); shuffle \(player.shuffleMode.rawValue), queue index \(player.indexOfNowPlayingItem)")
                let queue = SystemMusicPlayer.shared.queue
                say("MusicKit queue: current \(String(describing: queue.currentEntry?.item)); transient \(String(describing: queue.currentEntry?.isTransient))")
                if let item = player.nowPlayingItem {
                    say("item: cloud \(item.isCloudItem), media type \(item.mediaType.rawValue), protected \(item.hasProtectedAsset), album track \(item.albumTrackNumber), count \(item.albumTrackCount), in library \(item.persistentID != 0)")
                }
                say("playlist: \(String(describing: await phone.playlistPlace(remembered: nil)))")
                say("album: \(String(describing: await phone.albumPlace(remembered: nil)))")
                say("Apple Music: \(String(describing: await phone.appleMusicSource()))")
                say("library shuffled: \(await phone.isShufflingLibrary()); repeat \(String(describing: phone.repeatMode())); MediaPlayer repeat \(player.repeatMode.rawValue), MusicKit repeat \(String(describing: SystemMusicPlayer.shared.state.repeatMode))")
                if let at = arguments.firstIndex(of: "-setRepeat"), arguments.count > at + 1 {
                    phone.setRepeat(RepeatMode(rawValue: arguments[at + 1]))
                    try? await Task.sleep(for: .seconds(1))
                    say("after setRepeat \(arguments[at + 1]): MediaPlayer \(player.repeatMode.rawValue), MusicKit \(String(describing: SystemMusicPlayer.shared.state.repeatMode))")
                }
                finish()
            }
            return
        }
        if let at = arguments.firstIndex(of: "-stationPlayProbe"), arguments.count > at + 1 {
            // Plays the station Apple Music makes from this catalogue song.
            let id = arguments[at + 1]
            Task {
                do {
                    var request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(id))
                    request.properties = [.station]
                    guard let station = try await request.response().items.first?.station else { say("no station"); return finish() }
                    SystemMusicPlayer.shared.queue = SystemMusicPlayer.Queue(for: [station])
                    try await SystemMusicPlayer.shared.play()
                    try? await Task.sleep(for: .seconds(3))
                    say("station \(station.id): playing \(describe(MPMusicPlayerController.systemMusicPlayer.nowPlayingItem))")
                } catch {
                    say("station failed: \(error)")
                }
                finish()
            }
            return
        }
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
