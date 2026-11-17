import MediaPlayer
import MusicKit
import StandByKit

/// Apple Music on this phone for Continue on iPhone, through MediaPlayer's
/// system player. `setQueue(with:)` takes catalogue IDs (store IDs), and
/// `nowPlayingItem.playbackStoreID` gives the playing one back: both seen
/// matching the catalogue on an iPhone on 11 November 2026.
@MainActor
final class SystemMusicPhonePlayer: PhoneMusicPlaying {
    /// Opens the Music app, where Continue on iPhone leaves the song.
    nonisolated static let appURL = URL(string: "music://")!

    private let player = MPMusicPlayerController.systemMusicPlayer

    func requestAccess() async -> Bool {
        switch MPMediaLibrary.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                MPMediaLibrary.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
        default:
            return false
        }
    }

    func play(catalogIDs: [String], position: @escaping @MainActor () -> TimeInterval, timeout: TimeInterval) async -> Bool {
        guard let first = catalogIDs.first else { return false }
        // The Mac's order: its Up Next is already shuffled if it was shuffling.
        player.shuffleMode = .off
        player.setQueue(with: catalogIDs)
        let prepared = await withCheckedContinuation { continuation in
            player.prepareToPlay { continuation.resume(returning: $0 == nil) }
        }
        guard prepared else { return false }
        player.currentPlaybackTime = position()
        player.play()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if player.playbackState == .playing, player.nowPlayingItem?.playbackStoreID == first {
                // Starting can take a moment; land on where the Mac is now.
                let target = position()
                if abs(player.currentPlaybackTime - target) > 1.5 { player.currentPlaybackTime = target }
                return true
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    func nowPlaying() -> PhoneNowPlaying? {
        guard MPMediaLibrary.authorizationStatus() == .authorized, let item = player.nowPlayingItem else { return nil }
        let id = item.playbackStoreID
        return PhoneNowPlaying(catalogID: id.isEmpty || id == "0" ? nil : id, position: player.currentPlaybackTime,
                               isPlaying: player.playbackState == .playing, title: item.title)
    }

    func pause() { player.pause() }

    func resume() { player.play() }

    /// Apple Music's own catalogue search (MusicKit), for a song the Mac has
    /// no catalogue ID for: Apple's public search, which the Mac uses,
    /// doesn't have every song (16 November 2026).
    func searchCatalog(title: String, artist: String) async -> [CatalogCandidate] {
        guard access == .allowed else { return [] }
        var request = MusicCatalogSearchRequest(term: "\(title) \(artist)", types: [Song.self])
        request.limit = 15
        guard let songs = try? await request.response().songs else { return [] }
        return songs.map { CatalogCandidate(id: $0.id.rawValue, title: $0.title, artist: $0.artistName, duration: $0.duration) }
    }

    /// For the Continue Listening row (16 November 2026).
    var access: AppleMusicAccess {
        switch MPMediaLibrary.authorizationStatus() {
        case .authorized: .allowed
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    /// True when this phone can play from the Apple Music catalogue, as
    /// Continue on iPhone does; false without a subscription. Nil when it
    /// can't be told, as before Apple Music access is allowed or offline.
    func canPlayCatalog() async -> Bool? {
        guard access == .allowed else { return nil }
        return try? await MusicSubscription.current.canPlayCatalogContent
    }

    // MARK: Playlists (17 November 2026)

    /// Seen on this iPhone on 17 November 2026 (`HandoverProbe`): a library
    /// playlist found by name among 100 in 3 ms, with its 123 songs as on the
    /// Mac and song 40 the same song; `cloudGlobalID` is the `pl.u-…` ID that Apple
    /// Music's recently played gives; started from song 40 in 0.16 s, with
    /// `indexOfNowPlayingItem` 39, and the next song was 41.
    func playlistPlace(remembered: PlaylistPlace?) async -> PlaylistPlace? {
        guard access == .allowed, let item = player.nowPlayingItem else { return nil }
        let shuffled = player.shuffleMode != .off
        let queueIndex = player.indexOfNowPlayingItem
        // Shuffling, Music's queue can't confirm the playlist, so only the
        // latest one Apple Music lists is trusted.
        var candidates = await recentlyPlayed(considering: shuffled ? 1 : 3).filter { $0.kind == .playlist }.map { (name: $0.name, cloudID: $0.id) }
        if let remembered { candidates.append((remembered.name, remembered.knownCloudID)) }
        let library = Self.libraryPlaylists()
        for candidate in candidates {
            for playlist in Self.playlists(named: candidate.name, cloudID: candidate.cloudID, in: library) {
                let items = playlist.items
                let places = items.indices.filter { items[$0].persistentID == item.persistentID }
                guard let first = places.first else { continue }
                // Unshuffled, Music's queue is the playlist itself: the song's
                // place in the queue is its place in the playlist.
                if !shuffled, !places.contains(queueIndex) { continue }
                return PlaylistPlace(name: playlist.name ?? candidate.name, cloudID: playlist.cloudGlobalID, count: items.count,
                                     index: shuffled ? first : queueIndex, shuffled: shuffled ? true : nil)
            }
        }
        // Started here in the last minute or so, before Apple Music lists it
        // (a six-song playlist, 17 November 2026): the library playlist with this song
        // at the place Music's queue is at. The smallest such, so a folder
        // holding the playlist doesn't count against it. Unshuffled only:
        // shuffled, the queue's place isn't the playlist's.
        guard !shuffled, queueIndex != NSNotFound else { return nil }
        let matching = library.filter { playlist in
            let items = playlist.items
            return items.indices.contains(queueIndex) && items[queueIndex].persistentID == item.persistentID
        }
        guard let playlist = matching.min(by: { $0.count < $1.count }) else { return nil }
        return PlaylistPlace(name: playlist.name ?? "", cloudID: playlist.cloudGlobalID, count: playlist.count, index: queueIndex)
    }

    func play(_ catalogID: String, in place: PlaylistPlace, position: @escaping @MainActor () -> TimeInterval,
              timeout: TimeInterval) async -> PlaylistPlace? {
        guard access == .allowed else { return nil }
        let candidates = Self.playlists(named: place.name, cloudID: place.knownCloudID, in: Self.libraryPlaylists())
            .sorted { abs($0.count - place.count) < abs($1.count - place.count) }
        for playlist in candidates {
            let items = playlist.items
            guard let index = place.locate(catalogID, in: items.map(Self.catalogID)) else { continue }
            let item = items[index]
            // Shuffle only once the song plays: set first, Music starts the
            // shuffled queue anywhere (seen 17 November 2026).
            player.shuffleMode = .off
            player.setQueue(with: playlist)
            player.nowPlayingItem = item
            let prepared = await withCheckedContinuation { continuation in
                player.prepareToPlay { continuation.resume(returning: $0 == nil) }
            }
            guard prepared else { return nil }
            player.currentPlaybackTime = position()
            player.play()
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if player.playbackState == .playing, player.nowPlayingItem?.persistentID == item.persistentID {
                    let target = position()
                    if abs(player.currentPlaybackTime - target) > 1.5 { player.currentPlaybackTime = target }
                    if place.isShuffled { player.shuffleMode = .songs }
                    return PlaylistPlace(name: playlist.name ?? place.name, cloudID: playlist.cloudGlobalID, count: items.count,
                                         index: index, shuffled: place.shuffled)
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
            return nil
        }
        return nil
    }

    private static func libraryPlaylists() -> [MPMediaPlaylist] {
        (MPMediaQuery.playlists().collections ?? []).compactMap { $0 as? MPMediaPlaylist }
    }

    /// By Apple Music's ID when it's known and here; else by name, exactly,
    /// then ignoring case and accents.
    private static func playlists(named name: String, cloudID: String?, in library: [MPMediaPlaylist]) -> [MPMediaPlaylist] {
        if let cloudID {
            let byID = library.filter { $0.cloudGlobalID == cloudID }
            if !byID.isEmpty { return byID }
        }
        let exact = library.filter { $0.name == name }
        if !exact.isEmpty { return exact }
        return library.filter { $0.name?.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    private static func catalogID(of item: MPMediaItem) -> String? {
        let id = item.playbackStoreID
        return id.isEmpty || id == "0" ? nil : id
    }

    /// The latest `considering` things Apple Music lists as recently
    /// played, newest first: playlists and albums, by name and ID. It's
    /// account-wide, so the Mac's listening counts too, and something started
    /// here shows after about a minute. Apple's servers answer it, so a
    /// hand-over waits at most `recentlyPlayedWait` for them.
    private func recentlyPlayed(considering limit: Int) async -> [RecentlyPlayed] {
        guard MusicAuthorization.currentStatus == .authorized else { return [] }
        return await withTaskGroup(of: [RecentlyPlayed]?.self) { group in
            group.addTask {
                var request = MusicRecentlyPlayedContainerRequest()
                request.limit = limit
                guard let items = try? await request.response().items else { return [] }
                return items.prefix(limit).map { item -> RecentlyPlayed in
                    switch item {
                    case .playlist(let playlist): RecentlyPlayed(kind: .playlist, name: playlist.name, id: playlist.id.rawValue)
                    case .album(let album): RecentlyPlayed(kind: .album, name: album.title, id: album.id.rawValue)
                    default: RecentlyPlayed(kind: .other, name: "", id: nil)
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(for: Self.recentlyPlayedWait)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? []
        }
    }

    nonisolated static let recentlyPlayedWait: Duration = .seconds(3)

    struct RecentlyPlayed: Sendable {
        enum Kind: Sendable { case playlist, album, other }
        var kind: Kind
        var name: String
        var id: String?
    }

    /// The library album Apple Music here plays its current song from, for
    /// Continue on Mac when it isn't from a playlist (17 November 2026): the
    /// song's album in this library, with the song's place counted by disc,
    /// then track, as Music on the Mac counts. Unshuffled, Music's queue
    /// place must be that place, which shows the queue is the album.
    /// Shuffled, it must be the album Apple Music last lists as recently
    /// played. The Mac plays it in order either way: it can't shuffle within
    /// an album.
    func albumPlace() async -> AlbumPlace? {
        guard access == .allowed, let item = player.nowPlayingItem, item.albumPersistentID != 0 else { return nil }
        let query = MPMediaQuery.songs()
        query.addFilterPredicate(MPMediaPropertyPredicate(value: NSNumber(value: item.albumPersistentID),
                                                          forProperty: MPMediaItemPropertyAlbumPersistentID))
        let songs = (query.items ?? []).sorted {
            ($0.discNumber, $0.albumTrackNumber, $0.title ?? "") < ($1.discNumber, $1.albumTrackNumber, $1.title ?? "")
        }
        guard let index = songs.firstIndex(where: { $0.persistentID == item.persistentID }) else { return nil }
        let title = item.albumTitle ?? ""
        let shuffled = player.shuffleMode != .off
        if shuffled {
            guard let latest = await recentlyPlayed(considering: 1).first, latest.kind == .album,
                  latest.name.compare(title, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame else { return nil }
        } else {
            guard player.indexOfNowPlayingItem == index else { return nil }
        }
        return AlbumPlace(title: title, artist: item.albumArtist ?? item.artist, count: songs.count, index: index,
                          shuffled: shuffled ? true : nil)
    }

    /// Apple Music's station for the song (MusicKit's `Song.station`, the
    /// catalogue's Create Station), after the queue, through MusicKit's
    /// queue. Seen on the iPhone on 15 November 2026 (`StationProbe`): while
    /// playing, the station's songs kept coming after the Mac's (nine and
    /// counting); Playing Next shows only its next two. MediaPlayer's append
    /// by store ID instead looped the Mac's songs, so it isn't used. The
    /// catalogue needs the MusicKit app service on the App ID.
    func appendStation(seededBy catalogID: String) async -> StationAppend {
        let station: Station
        do {
            var request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(catalogID))
            request.properties = [.station]
            guard let found = try await request.response().items.first?.station else { return .noStation }
            station = found
        } catch {
            return .failed("catalogue: \(error.localizedDescription)")
        }
        do {
            try await SystemMusicPlayer.shared.queue.insert(station, position: .tail)
            return .added
        } catch {
            return .failed("queue: \(error.localizedDescription)")
        }
    }
}
