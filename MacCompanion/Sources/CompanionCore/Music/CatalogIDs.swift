import Foundation

/// Apple Music catalogue IDs for songs Music's remote protocol gives none
/// for: those played from Apple Music without being in the library. Seen on
/// 12 November 2026: an album played from the catalogue had only title,
/// artist, album, genre and length in Up Next, so only the one library song
/// moved to the phone.
public protocol CatalogIDLookup: Sendable {
    /// One answer per query, in order; nil where nothing matches closely enough.
    func catalogIDs(for queries: [CatalogQuery]) async -> [String?]
}

/// Through the iTunes Search API, as `ITunesCatalogArtwork` finds art. One
/// search per album, not per song; at most `searchesPerCall` a call, so an
/// autoplay queue of many albums fills in over a few songs rather than all
/// at once. It sends the album, lead artist and storefront, nothing else.
public actor ITunesCatalogIDs: CatalogIDLookup {
    public static let searchesPerCall = 4
    /// An album with no match isn't searched again for this long.
    public static let missRetry: TimeInterval = 1800

    private let country: String
    private let fetch: @Sendable (URL) async throws -> Data
    private let now: @Sendable () -> Date
    private var found: [String: String] = [:]
    private var albums: [String: [ITunesCatalogArtwork.Song]] = [:]
    private var missedAlbums: [String: Date] = [:]

    public init(country: String = Locale.current.region?.identifier ?? "US",
                fetch: (@Sendable (URL) async throws -> Data)? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.country = country
        self.now = now
        if let fetch {
            self.fetch = fetch
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 5
            configuration.waitsForConnectivity = false
            let session = URLSession(configuration: configuration)
            self.fetch = { url in
                let (data, response) = try await session.data(from: url)
                try ITunesCatalogArtwork.check(response)
                return data
            }
        }
    }

    public func catalogIDs(for queries: [CatalogQuery]) async -> [String?] {
        var searches = 0
        var answers: [String?] = []
        for query in queries {
            let key = Self.songKey(query)
            if let id = found[key] {
                answers.append(id)
                continue
            }
            let album = Self.albumKey(query)
            if albums[album] == nil, missedAlbums[album].map({ now().timeIntervalSince($0) >= Self.missRetry }) ?? true,
               searches < Self.searchesPerCall {
                searches += 1
                await search(album: album, for: query)
            }
            let match = albums[album].flatMap { ITunesCatalogArtwork.bestMatch(for: query, in: $0) }?.trackId.map(String.init)
            if let match { found[key] = match }
            answers.append(match)
        }
        return answers
    }

    private func search(album key: String, for query: CatalogQuery) async {
        let url = ITunesCatalogArtwork.albumSearchURL(artist: query.artist, album: query.album, country: country)
        do {
            let songs = try JSONDecoder().decode(ITunesCatalogArtwork.SearchResponse.self, from: try await fetch(url)).results
            if songs.isEmpty {
                missedAlbums[key] = now()
            } else {
                albums[key] = songs
                missedAlbums[key] = nil
            }
        } catch {
            missedAlbums[key] = now()
        }
    }

    static func albumKey(_ query: CatalogQuery) -> String {
        "\(ITunesCatalogArtwork.normalized(album: query.album))|\(ITunesCatalogArtwork.normalized(query.artist.components(separatedBy: CharacterSet(charactersIn: ",&;")).first ?? query.artist))"
    }

    static func songKey(_ query: CatalogQuery) -> String {
        "\(albumKey(query))|\(ITunesCatalogArtwork.normalized(query.title))|\(Int(query.duration.rounded()))"
    }
}

/// Music's remote protocol, with missing catalogue IDs looked up in the
/// catalogue: the current song when it isn't in the library, and Up Next.
public struct CatalogFillingRemote: MusicRemoteReading {
    public let remote: any MusicRemoteReading
    public let lookup: any CatalogIDLookup

    public init(remote: any MusicRemoteReading, lookup: any CatalogIDLookup) {
        self.remote = remote
        self.lookup = lookup
    }

    public func artwork(for track: MusicTrack) async -> Data? { await remote.artwork(for: track) }

    public func queue(current track: MusicTrack?) async -> RemoteQueue? {
        guard var queue = await remote.queue(current: track) else { return nil }
        var queries: [CatalogQuery] = []
        let fillCurrent = queue.catalogID == nil && track != nil
        if fillCurrent, let track {
            queries.append(CatalogQuery(title: track.title, artist: track.artist, album: track.album, duration: track.duration))
        }
        let missing = queue.upNext.indices.filter { queue.upNext[$0].catalogID == nil }
        queries += missing.map {
            let entry = queue.upNext[$0]
            return CatalogQuery(title: entry.title, artist: entry.artist, album: entry.album ?? "", duration: entry.duration)
        }
        guard !queries.isEmpty else { return queue }
        var answers = await lookup.catalogIDs(for: queries)[...]
        if fillCurrent { queue.catalogID = answers.popFirst() ?? nil }
        for index in missing { queue.upNext[index].catalogID = answers.popFirst() ?? nil }
        return queue
    }
}
