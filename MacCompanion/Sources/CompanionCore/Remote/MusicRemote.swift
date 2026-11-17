import Foundation
import Network
import os
import StandByProtocol

/// The companion paired with Music as a remote, the way Apple's iTunes Remote
/// app pairs: the GUID the companion gave Music, and the Bonjour name of
/// Music's `_touch-able._tcp` service that paired with it.
public struct MusicRemotePairing: Codable, Equatable, Sendable {
    public var guid: String
    public var serviceName: String

    public init(guid: String, serviceName: String) {
        self.guid = guid
        self.serviceName = serviceName
    }
}

/// What Music's remote protocol adds to AppleScript: the current song's Apple
/// Music catalogue ID, Up Next, and the library playlist the song plays from
/// when Up Next is the rest of it in order (17 November 2026).
public struct RemoteQueue: Equatable, Sendable {
    public var catalogID: String?
    public var upNext: [QueuedTrack]
    public var playlist: PlaylistPlace?

    public init(catalogID: String?, upNext: [QueuedTrack], playlist: PlaylistPlace? = nil) {
        self.catalogID = catalogID
        self.upNext = upNext
        self.playlist = playlist
    }
}

/// Continue on Mac's other half: Music plays a library playlist from one of
/// its songs, as Apple's Remote app does, so a playlist started on the
/// iPhone carries on here instead of becoming the song's station.
public protocol MusicRemotePlaying: Sendable {
    func play(_ catalogID: String, in place: PlaylistPlace) async -> PlaylistPlayOutcome
    /// Plays the library album that has this song, on from it in album
    /// order. `beforeStart` runs just before Music is told, only once the
    /// album is found: the companion turns shuffle off there.
    func playAlbum(_ catalogID: String, in place: AlbumPlace, beforeStart: @escaping @Sendable () async -> Void) async -> PlaylistPlayOutcome
}

extension MusicRemotePlaying {
    public func playAlbum(_ catalogID: String, in place: AlbumPlace, beforeStart: @escaping @Sendable () async -> Void) async -> PlaylistPlayOutcome {
        .failed("this remote can't play an album")
    }
}

public enum PlaylistPlayOutcome: Equatable, Sendable {
    /// Music plays the playlist from the song, which is at this place (from 0).
    case played(index: Int)
    /// No playlist of that name in this library has the song.
    case notHere
    /// Music couldn't be reached, or refused.
    case failed(String)
}

public protocol MusicRemoteReading: Sendable {
    /// The current song's catalogue ID (by its persistent ID), and Up Next.
    /// Nil when Music can't be reached or has forgotten the pairing.
    func queue(current track: MusicTrack?) async -> RemoteQueue?
    /// True once Music has answered that it no longer knows this pairing
    /// (Forget All Remotes, or a changed library): connect again.
    var isForgottenByMusic: Bool { get async }
    /// Music's own now-playing artwork, when Music is still playing this
    /// track. Nil when it isn't, has none, or can't be reached.
    func artwork(for track: MusicTrack) async -> Data?
}

extension MusicRemoteReading {
    public func artwork(for track: MusicTrack) async -> Data? { nil }
    public var isForgottenByMusic: Bool { get async { false } }
}

public enum MusicRemoteStatus: Equatable, Sendable {
    case unknown, connected, unreachable
    /// Music answered 503 to the pairing: "Forget All Remotes" was used, or
    /// Music's library changed. Pair again.
    case unpaired
}

/// HTTP to Music on this Mac. A seam for tests.
public protocol LocalHTTP: Sendable {
    func get(port: Int, path: String) async throws -> (status: Int, body: Data)
}

public struct URLSessionLocalHTTP: LocalHTTP {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.httpAdditionalHeaders = ["Viewer-Only-Client": "1", "User-Agent": "Remote/1021"]
        session = URLSession(configuration: configuration)
    }

    public func get(port: Int, path: String) async throws -> (status: Int, body: Data) {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { throw URLError(.badURL) }
        let (data, response) = try await session.data(from: url)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

/// Reads Music's Up Next and catalogue IDs over DACP. Verified against Music
/// on macOS 27 on 12 November 2026 with a test remote: every one of 12,679
/// library songs carried a catalogue ID (`aeSI`, `com.apple.itunes.itms-songid`)
/// that Apple's lookup confirmed, and `mper` equals AppleScript's persistent ID.
///
/// Its one action, from 17 November 2026: `play(_:in:)` starts a library
/// playlist from a song (`playspec`), for Continue on Mac. Everything else
/// only reads: it never skips or changes volume.
public actor MusicRemoteClient: MusicRemoteReading, MusicRemotePlaying {
    public static let libraryRefreshInterval: TimeInterval = 60

    private let pairing: MusicRemotePairing
    private let http: any LocalHTTP
    private let locate: @Sendable (String) async -> Int?
    private let now: @Sendable () -> Date
    private var port: Int?
    private var session: UInt64?
    private var catalogByPersistentID: [String: String] = [:]
    private var catalogByItemID: [UInt64: String] = [:]
    /// Catalogue ID → the album (`asai`) its library song is on.
    private var albumByCatalog: [String: UInt64] = [:]
    private var libraryReadAt: Date?
    /// The library's `miid`: `playspec` names the database by it.
    private var databaseID: UInt64?
    private var playlists: [UInt64: RemotePlaylist] = [:]
    private var playlistsReadAt: Date?
    private var songsByPlaylist: [UInt64: PlaylistSongs] = [:]
    public private(set) var status: MusicRemoteStatus = .unknown
    public var isForgottenByMusic: Bool { status == .unpaired }

    public init(pairing: MusicRemotePairing, http: any LocalHTTP = URLSessionLocalHTTP(),
                locate: @escaping @Sendable (String) async -> Int? = { await MusicRemoteLocator.port(serviceName: $0) },
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.pairing = pairing
        self.http = http
        self.locate = locate
        self.now = now
    }

    private enum Failure: Error { case unpaired, unreachable }

    public func queue(current track: MusicTrack?) async -> RemoteQueue? {
        let persistentID = track?.persistentID?.uppercased()
        do {
            if catalogByItemID.isEmpty || (persistentID.map { catalogByPersistentID[$0] == nil } ?? false) {
                try await refreshLibrary()
            }
            let body = try await get("/ctrl-int/1/playqueue-contents?span=\(PlaybackMessage.upNextLimit)")
            status = .connected
            let catalogID = persistentID.flatMap { catalogByPersistentID[$0] }
            // Best effort: without it, Continue on iPhone takes Up Next's songs.
            let playlist = try? await playlistPlace(current: catalogID, upNext: queueSpecs(from: body))
            return RemoteQueue(catalogID: catalogID, upNext: upNext(from: body), playlist: playlist)
        } catch Failure.unpaired {
            status = .unpaired
        } catch {
            status = .unreachable
            port = nil
            session = nil
        }
        return nil
    }

    /// `nowplayingartwork` at 600 px, after checking Music's now-playing title
    /// and artist are the track's, so a skip in between can't hand over the
    /// wrong cover. Measured 12 Nov 2026 on a song streamed from Apple Music,
    /// not in the library: AppleScript had no artwork, this had Music's 600 px
    /// cover (a 488 KB PNG) in 97 ms.
    public func artwork(for track: MusicTrack) async -> Data? {
        do {
            let status = DMAPNode.parse(try await get("/ctrl-int/1/playstatusupdate?revision-number=1"))
            func same(_ tag: String, _ value: String) -> Bool {
                status.first(tag).map { $0.string.compare(value, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame } ?? false
            }
            guard same("cann", track.title), same("cana", track.artist) else { return nil }
            let image = try await get("/ctrl-int/1/nowplayingartwork?mw=600&mh=600")
            return image.isEmpty ? nil : image
        } catch {
            return nil
        }
    }

    /// Persistent ID → catalogue ID for the whole library: about 0.3 s for
    /// 12,679 songs. At most once a minute, so a song Music doesn't know
    /// (the radio, say) doesn't cost a library read each time.
    private func refreshLibrary() async throws {
        if let readAt = libraryReadAt, now().timeIntervalSince(readAt) < Self.libraryRefreshInterval { return }
        libraryReadAt = now()
        let databases = DMAPNode.parse(try await get("/databases"))
        guard let database = databases.first("mlcl")?.first("miid")?.integer else { throw Failure.unreachable }
        databaseID = database
        let meta = "dmap.itemid,dmap.persistentid,com.apple.itunes.itms-songid,daap.songalbumid"
        let items = DMAPNode.parse(try await get("/databases/\(database)/items?type=music&meta=\(meta)"))
        var byPersistentID: [String: String] = [:]
        var byItemID: [UInt64: String] = [:]
        var albums: [String: UInt64] = [:]
        for item in items.first("mlcl")?.all("mlit") ?? [] {
            guard let catalog = item.all("aeSI").first?.integer, catalog != 0 else { continue }
            if let persistent = item.all("mper").first?.integer {
                byPersistentID[String(format: "%016llX", persistent)] = String(catalog)
            }
            if let id = item.all("miid").first?.integer { byItemID[id] = String(catalog) }
            if let album = item.all("asai").first?.integer, album != 0 { albums[String(catalog)] = album }
        }
        catalogByPersistentID = byPersistentID
        catalogByItemID = byItemID
        albumByCatalog = albums
    }

    /// Where each Up Next song comes from, in order: its playlist and its
    /// place there (`ceQs`, as `upNext(from:)` reads it).
    func queueSpecs(from body: Data) -> [QueueSpec] {
        (DMAPNode.parse(body).first("mlcl")?.all("mlit") ?? []).compactMap { entry in
            guard let spec = entry.all("ceQs").first?.value, spec.count == 16 else { return nil }
            func word(_ i: Int) -> UInt64 { spec.dropFirst(i * 4).prefix(4).reduce(UInt64(0)) { $0 << 8 | UInt64($1) } }
            return QueueSpec(playlist: word(1), playlistItem: word(2), item: word(3))
        }
    }

    // MARK: Playlists (17 November 2026)

    /// How long a read of the playlists, or of one playlist's songs, is
    /// trusted. Either read takes a few milliseconds (5 ms for 102
    /// playlists, 1 ms for 123 songs, on 17 November 2026).
    static let playlistRefreshInterval: TimeInterval = 30

    /// The playlist `current` plays from, when Up Next is the rest of it in
    /// order. Music doesn't say which playlist the current song comes from
    /// (`canp` names none), but each Up Next song carries its playlist and
    /// place, so: the first Up Next song's playlist, when the song before it
    /// there is `current` and the next few follow in order. Shuffled, or
    /// with songs added by Play Next, they don't, and it's nil.
    func playlistPlace(current catalogID: String?, upNext specs: [QueueSpec]) async throws -> PlaylistPlace? {
        guard let catalogID, let first = specs.first, first.playlist != 0 else { return nil }
        guard let playlist = try await knownPlaylist(first.playlist), playlist.isOwn else { return nil }
        var songs = try await readSongs(in: playlist, maxAge: Self.playlistRefreshInterval)
        if !songs.playlistItems.contains(first.playlistItem) { songs = try await readSongs(in: playlist, maxAge: 0) }
        guard let next = songs.playlistItems.firstIndex(of: first.playlistItem), next >= 1,
              songs.catalogIDs[next - 1] == catalogID else { return nil }
        for (offset, spec) in specs.prefix(Self.inOrderCheck).enumerated() {
            let place = next + offset
            // Past the playlist's end, Autoplay's songs follow (a six-song playlist, 17 November 2026).
            guard place < songs.playlistItems.count else { break }
            guard spec.playlist == playlist.id, songs.playlistItems[place] == spec.playlistItem else { return nil }
        }
        return PlaylistPlace(name: playlist.name, count: songs.playlistItems.count, index: next - 1)
    }

    /// How many Up Next songs must follow the playlist's order.
    static let inOrderCheck = 3

    /// Plays `place`'s playlist from the song: the playlist here with that
    /// name (the same size first) that has the song, at `place.index` or
    /// else the closest place. Music then plays the playlist on from it.
    /// The quotes in `playspec` must go as they are: Music answers `%27`
    /// with 500 (17 November 2026).
    public func play(_ catalogID: String, in place: PlaylistPlace) async -> PlaylistPlayOutcome {
        guard place.isValid else { return .notHere }
        do {
            let database = try await libraryDatabase()
            var candidates = try await playlists(named: place.name, maxAge: Self.playlistRefreshInterval)
            if candidates.isEmpty { candidates = try await playlists(named: place.name, maxAge: 0) }
            for playlist in candidates.sorted(by: { abs($0.count - place.count) < abs($1.count - place.count) }) {
                var songs = try await readSongs(in: playlist, maxAge: Self.playlistRefreshInterval)
                var index = place.locate(catalogID, in: songs.catalogIDs)
                if index == nil, now().timeIntervalSince(songs.readAt) > 1 {
                    songs = try await readSongs(in: playlist, maxAge: 0)
                    index = place.locate(catalogID, in: songs.catalogIDs)
                }
                guard let index else { continue }
                let answer = try await control("/ctrl-int/1/playspec?database-spec='dmap.itemid:\(database)'"
                    + "&container-spec='dmap.persistentid:0x\(String(playlist.persistentID, radix: 16))'"
                    + "&container-item-spec='dmap.containeritemid:\(songs.playlistItems[index])'")
                status = .connected
                guard answer == 200 || answer == 204 else { return .failed("Music answered playspec with \(answer)") }
                return .played(index: index)
            }
            return .notHere
        } catch Failure.unpaired {
            status = .unpaired
            return .failed("Music has forgotten this remote")
        } catch {
            status = .unreachable
            port = nil
            session = nil
            return .failed("Music's remote protocol didn't answer")
        }
    }

    // MARK: Albums (17 November 2026)

    /// Plays the library album with this song on from it, in album order:
    /// Music's `cue` over the album's songs, which counts them by disc, then
    /// track. Music's own listing of the album comes in another order, so
    /// the place is worked out here. Shuffle must be off, or Music draws from
    /// the whole library: `beforeStart` sees to that. The quotes go as they
    /// are, as for `playspec`. Seen on 17 November 2026: track 10 of a
    /// one-disc album, and disc 2 track 10 of a two-disc one as index 20.
    public func playAlbum(_ catalogID: String, in place: AlbumPlace,
                          beforeStart: @escaping @Sendable () async -> Void) async -> PlaylistPlayOutcome {
        guard place.isValid else { return .notHere }
        do {
            if albumByCatalog[catalogID] == nil {
                libraryReadAt = nil   // a song added since the last read
                try await refreshLibrary()
            }
            guard let album = albumByCatalog[catalogID] else { return .notHere }
            let database = try await libraryDatabase()
            let meta = "dmap.itemid,dmap.itemname,daap.songdiscnumber,daap.songtracknumber,com.apple.itunes.itms-songid"
            let list = DMAPNode.parse(try await get("/databases/\(database)/items?type=music&query='daap.songalbumid:\(album)'&meta=\(meta)"))
            let songs = (list.first("mlcl")?.all("mlit") ?? []).map { item in
                (disc: item.all("asdn").first?.integer ?? 0, track: item.all("astn").first?.integer ?? 0,
                 name: item.all("minm").first?.string ?? "",
                 catalogID: item.all("aeSI").first?.integer.flatMap { $0 == 0 ? nil : String($0) })
            }.sorted { ($0.disc, $0.track, $0.name) < ($1.disc, $1.track, $1.name) }
            let ids = songs.map(\.catalogID)
            guard let index = ids.indices.filter({ ids[$0] == catalogID }).min(by: { abs($0 - place.index) < abs($1 - place.index) }) else {
                return .notHere
            }
            await beforeStart()
            _ = try await control("/ctrl-int/1/cue?command=clear")
            let answer = try await control("/ctrl-int/1/cue?command=play&query='daap.songalbumid:\(album)'&index=\(index)&sort=album")
            status = .connected
            guard answer == 200 || answer == 204 else { return .failed("Music answered cue with \(answer)") }
            return .played(index: index)
        } catch Failure.unpaired {
            status = .unpaired
            return .failed("Music has forgotten this remote")
        } catch {
            status = .unreachable
            port = nil
            session = nil
            return .failed("Music's remote protocol didn't answer")
        }
    }

    private func libraryDatabase() async throws -> UInt64 {
        if let databaseID { return databaseID }
        let databases = DMAPNode.parse(try await get("/databases"))
        guard let id = databases.first("mlcl")?.first("miid")?.integer else { throw Failure.unreachable }
        databaseID = id
        return id
    }

    private func refreshPlaylists(maxAge: TimeInterval) async throws {
        if let readAt = playlistsReadAt, now().timeIntervalSince(readAt) <= maxAge, maxAge > 0 { return }
        let database = try await libraryDatabase()
        let meta = "dmap.itemid,dmap.itemname,dmap.persistentid,dmap.itemcount,daap.baseplaylist,com.apple.itunes.special-playlist"
        let list = DMAPNode.parse(try await get("/databases/\(database)/containers?meta=\(meta)"))
        var found: [UInt64: RemotePlaylist] = [:]
        for item in list.first("mlcl")?.all("mlit") ?? [] {
            guard let id = item.all("miid").first?.integer, let persistentID = item.all("mper").first?.integer else { continue }
            // The library itself (`abpl`) and Music's own lists (`aePS`, such as "Music") aren't playlists here.
            let isOwn = (item.all("abpl").first?.integer ?? 0) == 0 && (item.all("aePS").first?.integer ?? 0) == 0
            found[id] = RemotePlaylist(id: id, persistentID: persistentID, name: item.all("minm").first?.string ?? "",
                                       count: Int(item.all("mimc").first?.integer ?? 0), isOwn: isOwn)
        }
        playlists = found
        playlistsReadAt = now()
    }

    private func knownPlaylist(_ id: UInt64) async throws -> RemotePlaylist? {
        try await refreshPlaylists(maxAge: Self.playlistRefreshInterval)
        if playlists[id] == nil { try await refreshPlaylists(maxAge: 0) }
        return playlists[id]
    }

    /// The library's playlists with this name: exactly, or else ignoring case and accents.
    private func playlists(named name: String, maxAge: TimeInterval) async throws -> [RemotePlaylist] {
        try await refreshPlaylists(maxAge: maxAge)
        let own = playlists.values.filter(\.isOwn)
        let exact = own.filter { $0.name == name }
        if !exact.isEmpty { return exact }
        return own.filter { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    private func readSongs(in playlist: RemotePlaylist, maxAge: TimeInterval) async throws -> PlaylistSongs {
        if let cached = songsByPlaylist[playlist.id], maxAge > 0, now().timeIntervalSince(cached.readAt) <= maxAge { return cached }
        let database = try await libraryDatabase()
        let meta = "dmap.containeritemid,com.apple.itunes.itms-songid"
        let list = DMAPNode.parse(try await get("/databases/\(database)/containers/\(playlist.id)/items?type=music&meta=\(meta)"))
        var songs = PlaylistSongs(playlistItems: [], catalogIDs: [], readAt: now())
        for item in list.first("mlcl")?.all("mlit") ?? [] {
            guard let playlistItem = item.all("mcti").first?.integer else { continue }
            songs.playlistItems.append(playlistItem)
            songs.catalogIDs.append(item.all("aeSI").first?.integer.flatMap { $0 == 0 ? nil : String($0) })
        }
        songsByPlaylist[playlist.id] = songs
        return songs
    }

    /// A command: Music answers 204 with nothing when it's done.
    private func control(_ path: String) async throws -> Int {
        for attempt in 0..<2 {
            let session = try await login()
            let (status, _) = try await raw("\(path)&session-id=\(session)")
            if status == 401, attempt == 0 { self.session = nil; continue }
            return status
        }
        throw Failure.unreachable
    }

    /// Up Next from `playqueue-contents`: its `mlit`s that name a song (a
    /// `ceQs` of database, container, container item and item, 4 bytes each).
    func upNext(from body: Data) -> [QueuedTrack] {
        let list = DMAPNode.parse(body).first("mlcl")?.all("mlit") ?? []
        return list.compactMap { entry -> QueuedTrack? in
            guard let spec = entry.all("ceQs").first?.value, spec.count == 16 else { return nil }
            let itemID = spec.suffix(4).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            return QueuedTrack(catalogID: catalogByItemID[itemID],
                               title: entry.all("ceQn").first?.string ?? "",
                               artist: entry.all("ceQr").first?.string ?? "",
                               album: entry.all("ceQa").first?.string,
                               duration: Double(entry.all("astm").first?.integer ?? 0) / 1000)
        }
        .prefix(PlaybackMessage.upNextLimit).map { $0 }
    }

    /// A GET with the session, logging in first, and once again if Music
    /// has let the session go.
    private func get(_ path: String) async throws -> Data {
        for attempt in 0..<2 {
            let session = try await login()
            let separator = path.contains("?") ? "&" : "?"
            let (status, body) = try await raw("\(path)\(separator)session-id=\(session)")
            if status == 200 { return body }
            if status == 401 || status == 403, attempt == 0 { self.session = nil; continue }
            throw Failure.unreachable
        }
        throw Failure.unreachable
    }

    private func login() async throws -> UInt64 {
        if let session { return session }
        let (status, body) = try await raw("/login?pairing-guid=0x\(pairing.guid)")
        if status == 503 { throw Failure.unpaired }
        guard status == 200, let id = DMAPNode.parse(body).first("mlid")?.integer else { throw Failure.unreachable }
        session = id
        return id
    }

    private func raw(_ path: String) async throws -> (status: Int, body: Data) {
        if port == nil { port = await locate(pairing.serviceName) }
        guard let port else { throw Failure.unreachable }
        do {
            return try await http.get(port: port, path: path)
        } catch {
            self.port = nil
            throw Failure.unreachable
        }
    }
}

/// Where one Up Next song comes from: its playlist (`miid`; 0 for none),
/// its place there (`mcti`), and the song (`miid`).
struct QueueSpec: Equatable, Sendable {
    var playlist: UInt64
    var playlistItem: UInt64
    var item: UInt64
}

/// A playlist in Music's library, as its remote protocol lists it.
struct RemotePlaylist: Equatable, Sendable {
    var id: UInt64
    var persistentID: UInt64
    var name: String
    var count: Int
    /// A playlist of the person's own, not the library or one of Music's lists.
    var isOwn: Bool
}

/// One playlist's songs in order: each one's place (`mcti`) and catalogue ID.
struct PlaylistSongs: Equatable, Sendable {
    var playlistItems: [UInt64]
    var catalogIDs: [String?]
    var readAt: Date
}

/// Finds Music's DACP port. Music advertises `_touch-able._tcp` once it has a
/// paired remote; the port changes when Music restarts.
public enum MusicRemoteLocator {
    public static func port(serviceName: String, timeout: Duration = .seconds(3)) async -> Int? {
        let queue = DispatchQueue(label: "MusicRemoteLocator")
        let browser = NWBrowser(for: .bonjour(type: "_touch-able._tcp", domain: "local."), using: .tcp)
        let found = OSAllocatedUnfairLock<CheckedContinuation<Int?, Never>?>(initialState: nil)
        let connection = OSAllocatedUnfairLock<NWConnection?>(initialState: nil)
        let finish: @Sendable (Int?) -> Void = { port in
            let waiting = found.withLock { continuation -> CheckedContinuation<Int?, Never>? in
                defer { continuation = nil }
                return continuation
            }
            browser.cancel()
            connection.withLock { $0?.cancel() }
            waiting?.resume(returning: port)
        }
        return await withCheckedContinuation { continuation in
            found.withLock { $0 = continuation }
            browser.browseResultsChangedHandler = { results, _ in
                guard let result = results.first(where: {
                    if case .service(let name, _, _, _) = $0.endpoint { return name == serviceName }
                    return false
                }) else { return }
                let probe = NWConnection(to: result.endpoint, using: .tcp)
                connection.withLock { $0?.cancel(); $0 = probe }
                probe.stateUpdateHandler = { state in
                    guard case .ready = state else { return }
                    if case .hostPort(_, let port)? = probe.currentPath?.remoteEndpoint { finish(Int(port.rawValue)) }
                }
                probe.start(queue: queue)
            }
            browser.start(queue: queue)
            Task {
                try? await Task.sleep(for: timeout)
                finish(nil)
            }
        }
    }
}
