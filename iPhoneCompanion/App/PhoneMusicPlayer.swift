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

    /// Made on first use, never at init. Touching the system player makes
    /// iOS launch the Music app in the background, and Music then takes the
    /// Lock Screen's Now Playing slot. The app is made at every launch,
    /// including the background ones from the reminder and the Show in Now
    /// Playing automation, so an eager player hid Second Chair's player each
    /// time (21 November 2026, seen in the device log).
    private lazy var player = MPMusicPlayerController.systemMusicPlayer
    /// The Apple Music playlist or album `appleMusicSource()` found last,
    /// for `addToLibrary`.
    private var lastFound: FoundContainer?
    /// Apple Music's newest recently played, kept for one hand-over.
    private var recentCache: (at: Date, items: [RecentlyPlayedMusicItem])?
    private enum FoundContainer { case playlist(Playlist), album(Album) }

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
                if abs(player.currentPlaybackTime - target) > 0.5 { player.currentPlaybackTime = target }
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
        let library = Self.libraryPlaylists()
        func find(_ candidates: [(name: String, cloudID: String?)]) -> PlaylistPlace? {
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
            return nil
        }
        // Unshuffled, the remembered playlist is confirmed by the queue alone,
        // so it's tried before Apple's servers are asked (19 November 2026:
        // each ask cost up to 3 s).
        if !shuffled, let remembered, let found = find([(remembered.name, remembered.knownCloudID)]) { return found }
        // Shuffling, Music's queue can't confirm the playlist, so only the
        // latest one Apple Music lists is trusted.
        var candidates = await recentlyPlayed(considering: shuffled ? 1 : 3).filter { $0.kind == .playlist }.map { (name: $0.name, cloudID: $0.id) }
        if let remembered { candidates.append((remembered.name, remembered.knownCloudID)) }
        if let found = find(candidates) { return found }
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
                    if abs(player.currentPlaybackTime - target) > 0.5 { player.currentPlaybackTime = target }
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
        (await recentContainers(limit) ?? []).map { item -> RecentlyPlayed in
            switch item {
            case .playlist(let playlist): RecentlyPlayed(kind: .playlist, name: playlist.name, id: playlist.id.rawValue)
            case .album(let album): RecentlyPlayed(kind: .album, name: album.title, id: album.id.rawValue)
            default: RecentlyPlayed(kind: .other, name: "", id: nil)
            }
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
    func albumPlace(remembered: AlbumPlace?) async -> AlbumPlace? {
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
            // The album Continue on iPhone started here: no network needed,
            // and Apple Music never lists one an app queued (soak test, 19
            // November 2026: it sent the library shuffled instead).
            let artist = item.albumArtist ?? item.artist
            func same(_ a: String?, _ b: String?) -> Bool {
                (a ?? "").compare(b ?? "", options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }
            let rememberedHere = remembered.map { same($0.title, title) && same($0.artist, artist) } ?? false
            if !rememberedHere {
                guard let latest = await recentlyPlayed(considering: 1).first, latest.kind == .album,
                      latest.name.compare(title, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame else { return nil }
            }
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

// MARK: Albums, the library, Apple Music and repeat (17 November 2026)

extension SystemMusicPhonePlayer {
    /// A library song by catalogue ID. MediaPlayer can't filter by it, so the
    /// library's songs are scanned: 3,312 of them, in milliseconds.
    private static func librarySong(_ catalogID: String) -> MPMediaItem? {
        (MPMediaQuery.songs().items ?? []).first { $0.playbackStoreID == catalogID }
    }

    /// The library's songs from `item`'s album, by disc, then track, as Music on the Mac counts.
    private static func albumSongs(of item: MPMediaItem) -> [MPMediaItem] {
        let query = MPMediaQuery.songs()
        query.addFilterPredicate(MPMediaPropertyPredicate(value: NSNumber(value: item.albumPersistentID),
                                                          forProperty: MPMediaItemPropertyAlbumPersistentID))
        return (query.items ?? []).sorted {
            ($0.discNumber, $0.albumTrackNumber, $0.title ?? "") < ($1.discNumber, $1.albumTrackNumber, $1.title ?? "")
        }
    }

    /// Starts `item` in the queue already set, from `position()`, and waits
    /// for it to play; then shuffles the rest if asked. Shuffle set before the
    /// start makes Music start anywhere (seen 17 November 2026).
    private func start(_ item: MPMediaItem, position: @escaping @MainActor () -> TimeInterval, timeout: TimeInterval,
                       shuffle: Bool) async -> Bool {
        player.nowPlayingItem = item
        let prepared = await withCheckedContinuation { continuation in
            player.prepareToPlay { continuation.resume(returning: $0 == nil) }
        }
        guard prepared else { return false }
        player.currentPlaybackTime = position()
        player.play()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if player.playbackState == .playing, player.nowPlayingItem?.persistentID == item.persistentID {
                let target = position()
                if abs(player.currentPlaybackTime - target) > 0.5 { player.currentPlaybackTime = target }
                if shuffle { player.shuffleMode = .songs }
                return true
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return false
    }

    func play(_ catalogID: String, inAlbum place: AlbumPlace, position: @escaping @MainActor () -> TimeInterval,
              timeout: TimeInterval) async -> AlbumPlace? {
        guard access == .allowed, let item = Self.librarySong(catalogID), item.albumPersistentID != 0 else { return nil }
        let songs = Self.albumSongs(of: item)
        let ids = songs.map(Self.catalogID)
        guard let index = ids.indices.filter({ ids[$0] == catalogID }).min(by: { abs($0 - place.index) < abs($1 - place.index) }) else {
            return nil
        }
        player.shuffleMode = .off
        player.setQueue(with: MPMediaItemCollection(items: songs))
        guard await start(songs[index], position: position, timeout: timeout, shuffle: place.isShuffled) else { return nil }
        return AlbumPlace(title: item.albumTitle ?? place.title, artist: item.albumArtist ?? item.artist, count: songs.count, index: index,
                          shuffled: place.shuffled)
    }

    /// Seen on this iPhone on 17 November 2026 (`HandoverProbe`): the whole
    /// library queued, started on a song, then shuffled, kept the song and
    /// went on to other artists' songs.
    func playShuffledLibrary(from catalogID: String, position: @escaping @MainActor () -> TimeInterval, timeout: TimeInterval) async -> Bool {
        guard access == .allowed, let item = Self.librarySong(catalogID) else { return false }
        player.shuffleMode = .off
        player.setQueue(with: MPMediaQuery.songs())
        return await start(item, position: position, timeout: timeout, shuffle: true)
    }

    func isShufflingLibrary() async -> Bool {
        guard access == .allowed, player.shuffleMode != .off, let item = player.nowPlayingItem else { return false }
        let query = MPMediaQuery.songs()
        query.addFilterPredicate(MPMediaPropertyPredicate(value: NSNumber(value: item.persistentID), forProperty: MPMediaItemPropertyPersistentID))
        return !(query.items ?? []).isEmpty
    }

    // MARK: Apple Music outside the library

    /// The newest `limit` things Apple Music lists as recently played, as
    /// MusicKit gives them, within `recentlyPlayedWait`; nil when Apple's
    /// servers didn't answer in that time.
    ///
    /// One request serves a whole hand-over: the newest three are kept for
    /// `recentCacheLife`, and each caller takes what it needs. Before
    /// 19 November 2026 each caller asked Apple's servers itself, up to 3 s
    /// apiece, and a hand-over asked three times. No answer isn't kept, so
    /// the next caller asks again (26 November 2026).
    private func recentContainers(_ limit: Int) async -> [RecentlyPlayedMusicItem]? {
        guard MusicAuthorization.currentStatus == .authorized else { return [] }
        if let cached = recentCache, Date().timeIntervalSince(cached.at) < Self.recentCacheLife {
            return Array(cached.items.prefix(limit))
        }
        guard let items = await Self.fetchRecentContainers(3) else { return nil }
        recentCache = (Date(), items)
        return Array(items.prefix(limit))
    }

    nonisolated static let recentCacheLife: TimeInterval = 15

    private nonisolated static func fetchRecentContainers(_ limit: Int) async -> [RecentlyPlayedMusicItem]? {
        await withTaskGroup(of: [RecentlyPlayedMusicItem]?.self) { group in
            group.addTask {
                var request = MusicRecentlyPlayedContainerRequest()
                request.limit = limit
                guard let items = try? await request.response().items else { return nil }
                return Array(items.prefix(limit))
            }
            group.addTask {
                try? await Task.sleep(for: Self.recentlyPlayedWait)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// A playlist with its songs: up to 1,000, in batches of 100.
    private static func withEntries(_ playlist: Playlist) async -> (Playlist, [Playlist.Entry])? {
        guard let loaded = try? await playlist.with([.entries]), var batch = loaded.entries else { return nil }
        var all = Array(batch)
        for _ in 0..<9 where batch.hasNextBatch {
            guard let next = try? await batch.nextBatch() else { break }
            all += next
            batch = next
        }
        return (loaded, all)
    }

    /// An album with its songs, by disc, then track.
    private static func withTracks(_ album: Album) async -> (Album, [Track])? {
        guard let loaded = try? await album.with([.tracks]), let tracks = loaded.tracks else { return nil }
        let sorted = tracks.sorted { ($0.discNumber ?? 0, $0.trackNumber ?? 0, $0.title) < ($1.discNumber ?? 0, $1.trackNumber ?? 0, $1.title) }
        return (loaded, sorted)
    }

    private static func songID(_ entry: Playlist.Entry) -> String? {
        switch entry.item {
        case .song(let song)?: song.id.rawValue
        case .musicVideo(let video)?: video.id.rawValue
        default: nil
        }
    }

    /// The same song: by catalogue ID, or else by title and artist, as a
    /// library list's songs carry library IDs.
    private static func isSong(id: String?, title: String, artist: String?, _ catalogID: String?, _ item: MPMediaItem?) -> Bool {
        if let id, let catalogID, id == catalogID { return true }
        guard let item, let itemTitle = item.title else { return false }
        return CatalogCandidate.fold(title) == CatalogCandidate.fold(itemTitle)
            && CatalogCandidate.fold(artist ?? "") == CatalogCandidate.fold(item.artist ?? "")
    }

    func appleMusicSource() async -> AppleMusicSource? {
        guard access == .allowed, let item = player.nowPlayingItem else { return nil }
        let catalogID = Self.catalogID(of: item)
        let shuffled = player.shuffleMode != .off
        let queueIndex = player.indexOfNowPlayingItem
        // Shuffling, Music's queue can't confirm a list, so only the latest is trusted.
        for (n, container) in (await recentContainers(shuffled ? 1 : 2) ?? []).enumerated() {
            switch container {
            case .playlist(let playlist):
                guard let (loaded, entries) = await Self.withEntries(playlist) else { continue }
                let places = entries.indices.filter {
                    Self.isSong(id: Self.songID(entries[$0]), title: entries[$0].title, artist: entries[$0].artistName, catalogID, item)
                }
                guard let first = places.first else { continue }
                lastFound = .playlist(loaded)
                return .playlist(PlaylistPlace(name: loaded.name, cloudID: loaded.id.rawValue, count: entries.count,
                                               index: !shuffled && places.contains(queueIndex) ? queueIndex : first,
                                               shuffled: shuffled ? true : nil))
            case .album(let album):
                guard let (loaded, tracks) = await Self.withTracks(album),
                      let index = tracks.firstIndex(where: { Self.isSong(id: $0.id.rawValue, title: $0.title, artist: $0.artistName, catalogID, item) })
                else { continue }
                lastFound = .album(loaded)
                return .album(AlbumPlace(title: loaded.title, artist: loaded.artistName, count: tracks.count, index: index,
                                         shuffled: shuffled ? true : nil), id: loaded.id.rawValue)
            case .station(let station):
                // Only the latest, and only unshuffled: a station's songs can't be
                // checked, and a station can't shuffle. Seen 17 November 2026: the
                // library shuffled here, with an old station still latest.
                guard n == 0, !shuffled else { continue }
                return .station(StationPlace(id: station.id.rawValue, name: station.name))
            @unknown default:
                continue
            }
        }
        return nil
    }

    /// Seen on this iPhone on 17 November 2026 (`HandoverProbe`): an Apple
    /// Music playlist added in 5.4 s, and on the Mac 4.3 s later. A library
    /// list (`pl.u-…`, `l.…`) is there already.
    func addToLibrary(_ source: AppleMusicSource) async -> Bool {
        do {
            switch (source, lastFound) {
            case (.playlist(let place), .playlist(let playlist)?) where playlist.id.rawValue == place.cloudID:
                if playlist.id.rawValue.hasPrefix("pl.u-") { return true }
                do {
                    try await MusicLibrary.shared.add(playlist)
                } catch {
                    // Recently played's copy may not be addable: the catalogue's is.
                    let request = MusicCatalogResourceRequest<Playlist>(matching: \.id, equalTo: playlist.id)
                    guard let catalog = try await request.response().items.first else { throw error }
                    try await MusicLibrary.shared.add(catalog)
                }
            case (.album(_, let id), .album(let album)?) where album.id.rawValue == id:
                if id.hasPrefix("l.") { return true }
                do {
                    try await MusicLibrary.shared.add(album)
                } catch {
                    let request = MusicCatalogResourceRequest<Album>(matching: \.id, equalTo: album.id)
                    guard let catalog = try await request.response().items.first else { throw error }
                    try await MusicLibrary.shared.add(catalog)
                }
            default:
                return false
            }
            return true
        } catch {
            return false
        }
    }

    /// What the Mac plays from, in Apple Music's recently played: the
    /// newest two playlists or albums with this song, or, with
    /// `allowStation`, the newest item when it's a station.
    enum RecentFind {
        case playlist(Playlist, [Playlist.Entry], index: Int)
        case album(Album, [Track], index: Int)
        case station(Station)
    }

    /// `following` is what the Mac queues after the song. A playlist or album
    /// that has the song only counts when its songs match (`ContainerMatch`):
    /// a song's own album always has it (seen 19 November 2026). With
    /// `title`, the song also counts under another catalogue ID, and in a
    /// list in the library, whose songs have library IDs. The newest three
    /// are looked at; `note` hears why none counted.
    func findInRecentlyPlayed(_ catalogID: String, title: String? = nil, artist: String? = nil, allowStation: Bool,
                              following: [QueuedTrack] = [], shuffled: Bool = false,
                              note: @MainActor (String) -> Void = { _ in }) async -> RecentFind? {
        guard access == .allowed else { return nil }
        guard let recent = await recentContainers(3) else {
            note("recently played didn't answer")
            return nil
        }
        var seen: [String] = []
        func place(in songs: [ContainerMatch.Song], _ kind: String) -> Int? {
            if let index = ContainerMatch.place(of: catalogID, title: title, artist: artist, in: songs, following: following,
                                                inOrder: !shuffled) { return index }
            let has = ContainerMatch.place(of: catalogID, title: title, artist: artist, in: songs, following: [], inOrder: true) != nil
            seen.append(has ? "\(kind) whose next songs aren't the Mac's" : "\(kind) without the song")
            return nil
        }
        for (n, container) in recent.enumerated() {
            switch container {
            case .playlist(let playlist):
                guard let (loaded, entries) = await Self.withEntries(playlist) else {
                    seen.append("a playlist that didn't load")
                    continue
                }
                guard let index = place(in: entries.map(Self.listed), "a playlist") else { continue }
                return .playlist(loaded, entries, index: index)
            case .album(let album):
                guard let (loaded, tracks) = await Self.withTracks(album) else {
                    seen.append("an album that didn't load")
                    continue
                }
                guard let index = place(in: tracks.map(Self.listed), Self.isCatalogID(loaded.id.rawValue) ? "an album" : "a library album")
                else { continue }
                return .album(loaded, tracks, index: index)
            case .station(let station):
                guard n == 0, allowStation else {
                    seen.append("a station")
                    continue
                }
                return .station(station)
            @unknown default:
                continue
            }
        }
        note(seen.isEmpty ? "recently played lists nothing" : "recently played has \(seen.joined(separator: ", "))")
        return nil
    }

    private static func listed(_ entry: Playlist.Entry) -> ContainerMatch.Song {
        .init(id: songID(entry), title: entry.title, artist: entry.artistName)
    }

    private static func listed(_ track: Track) -> ContainerMatch.Song {
        .init(id: track.id.rawValue, title: track.title, artist: track.artistName)
    }

    /// A catalogue ID is digits; the library's are `l.…`, `i.…`, `p.…`.
    private static func isCatalogID(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy(\.isNumber)
    }

    /// The song's own album in the catalogue, when the Mac's next songs
    /// follow it there: for an album recently played doesn't list (yet), or
    /// lists as the library's copy, which has only the songs in the library
    /// (26 November 2026). At least one of the Mac's next songs must agree,
    /// so a playlist that merely has the song isn't taken for its album.
    private func catalogAlbum(of catalogID: String, title: String, artist: String, following: [QueuedTrack],
                              shuffled: Bool) async -> (album: Album, tracks: [Track], index: Int)? {
        var request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(catalogID))
        request.properties = [.albums]
        guard let albums = try? await request.response().items.first?.albums else { return nil }
        for album in albums.prefix(2) {
            guard let (loaded, tracks) = await Self.withTracks(album),
                  let index = ContainerMatch.place(of: catalogID, title: title, artist: artist, in: tracks.map(Self.listed),
                                                   following: following, inOrder: !shuffled, atLeast: 1) else { continue }
            return (loaded, tracks, index)
        }
        return nil
    }

    /// `task`'s value, or nil once `seconds` pass; the task carries on.
    private static func value<T: Sendable>(of task: Task<T?, Never>, within seconds: TimeInterval) async -> T? {
        guard seconds > 0 else { return nil }
        return await withTaskGroup(of: T?.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// How long a hand-over keeps for the list to start once it's found.
    private static let startReserve: TimeInterval = 3

    func playFromAppleMusic(_ catalogID: String, title: String, artist: String, position: @escaping @MainActor () -> TimeInterval,
                            timeout: TimeInterval, shuffled: Bool, allowStation: Bool, following: [QueuedTrack],
                            note: @escaping @MainActor (String) -> Void) async -> AppleMusicSource? {
        let started = Date()
        func left(keeping reserve: TimeInterval = 0) -> TimeInterval { max(1, timeout - Date().timeIntervalSince(started) - reserve) }
        // Alongside recently played: the song's own album in the catalogue.
        let ownAlbum = Task { await self.catalogAlbum(of: catalogID, title: title, artist: artist, following: following, shuffled: shuffled) }
        defer { ownAlbum.cancel() }
        var found = await findInRecentlyPlayed(catalogID, title: title, artist: artist, allowStation: allowStation,
                                               following: following, shuffled: shuffled, note: note)
        // The library's copy of an album has only the songs in the library;
        // the catalogue's has them all.
        var libraryAlbum = false
        if case .album(let album, _, _)? = found { libraryAlbum = !Self.isCatalogID(album.id.rawValue) }
        if found == nil || libraryAlbum {
            if let own = await Self.value(of: ownAlbum, within: left(keeping: Self.startReserve)) {
                if found == nil { note("found the Mac's album through the song, as recently played doesn't list it") }
                found = .album(own.album, own.tracks, index: own.index)
            } else if found == nil {
                note("the song's own album doesn't match the Mac's next songs, or didn't answer in time")
            }
        }
        guard let found else { return nil }
        switch found {
        case .playlist(let playlist, let entries, let index):
            player.shuffleMode = .off
            SystemMusicPlayer.shared.queue = SystemMusicPlayer.Queue(playlist: playlist, startingAt: entries[index])
            // The playlist's own ID for the song (found by title if the search
            // here found another release), the Mac's, or its name.
            let song = ContainerMatch.Expected(catalogIDs: Set([catalogID, Self.songID(entries[index])].compactMap { $0 }),
                                               title: entries[index].title, artist: entries[index].artistName)
            guard await startAppleMusic(song, position: position, timeout: left(), shuffle: shuffled) else {
                note("the playlist didn't start here")
                return nil
            }
            return .playlist(PlaylistPlace(name: playlist.name, cloudID: playlist.id.rawValue, count: entries.count, index: index,
                                           shuffled: shuffled ? true : nil))
        case .album(let album, let tracks, let index):
            player.shuffleMode = .off
            SystemMusicPlayer.shared.queue = SystemMusicPlayer.Queue(album: album, startingAt: tracks[index])
            let song = ContainerMatch.Expected(catalogIDs: [catalogID, tracks[index].id.rawValue],
                                               title: tracks[index].title, artist: tracks[index].artistName)
            guard await startAppleMusic(song, position: position, timeout: left(), shuffle: shuffled) else {
                note("the album didn't start here")
                return nil
            }
            return .album(AlbumPlace(title: album.title, artist: album.artistName, count: tracks.count, index: index,
                                     shuffled: shuffled ? true : nil), id: album.id.rawValue)
        case .station(let station):
            // The song first, then the station: a station started here
            // would begin on a song of its own.
            guard await play(catalogIDs: [catalogID], position: position, timeout: left()) else { return nil }
            do {
                try await SystemMusicPlayer.shared.queue.insert(station, position: .tail)
            } catch {
                return nil
            }
            return .station(StationPlace(id: station.id.rawValue, name: station.name))
        }
    }

    /// Plays the MusicKit queue just set and waits for its first song, at
    /// `position()`. It counts as playing by any of its catalogue IDs, or
    /// else by title and artist (`ContainerMatch.Expected`). If it doesn't
    /// start, the queue stops, so the Mac's next songs can take its place
    /// cleanly.
    private func startAppleMusic(_ song: ContainerMatch.Expected, position: @escaping @MainActor () -> TimeInterval,
                                 timeout: TimeInterval, shuffle: Bool) async -> Bool {
        do {
            try await SystemMusicPlayer.shared.prepareToPlay()
            try await SystemMusicPlayer.shared.play()
        } catch {
            return false
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if player.playbackState == .playing, let item = player.nowPlayingItem,
               song.isPlaying(storeID: item.playbackStoreID, title: item.title, artist: item.artist) {
                player.currentPlaybackTime = position()
                if shuffle { player.shuffleMode = .songs }
                return true
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        SystemMusicPlayer.shared.stop()
        return false
    }

    /// In the Mac's order: a catalogue request needn't keep it. Through
    /// MusicKit's queue, as a station is added (`appendStation`).
    func appendSongs(_ catalogIDs: [String]) async -> Int {
        guard !catalogIDs.isEmpty else { return 0 }
        let request = MusicCatalogResourceRequest<Song>(matching: \.id, memberOf: catalogIDs.map { MusicItemID($0) })
        guard let found = try? await request.response().items else { return 0 }
        let byID = Dictionary(found.map { ($0.id.rawValue, $0) }, uniquingKeysWith: { first, _ in first })
        let songs = catalogIDs.compactMap { byID[$0] }
        guard !songs.isEmpty else { return 0 }
        do {
            try await SystemMusicPlayer.shared.queue.insert(songs, position: .tail)
            return songs.count
        } catch {
            return 0
        }
    }

    // MARK: Repeat

    /// MediaPlayer's: on 17 November 2026 it read "one" after Continue on
    /// iPhone set it, while MusicKit's `state.repeatMode` still said none.
    /// MusicKit's only when MediaPlayer leaves it to the Music app.
    func repeatMode() -> RepeatMode? {
        switch player.repeatMode {
        case .none: return .off
        case .one: return .one
        case .all: return .all
        default:
            switch SystemMusicPlayer.shared.state.repeatMode {
            case .none?: return .off
            case .one?: return .one
            case .all?: return .all
            default: return nil
            }
        }
    }

    func setRepeat(_ mode: RepeatMode) {
        switch mode {
        case .off: player.repeatMode = .none
        case .one: player.repeatMode = .one
        case .all: player.repeatMode = .all
        default: break
        }
    }
}
