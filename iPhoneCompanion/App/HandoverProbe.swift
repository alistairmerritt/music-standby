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
