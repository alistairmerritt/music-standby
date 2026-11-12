import Foundation

/// What a catalogue lookup is told about a track: no more than the phone shows.
public struct CatalogQuery: Equatable, Sendable {
    public var title: String
    public var artist: String
    public var album: String
    public var duration: TimeInterval

    public init(title: String, artist: String, album: String, duration: TimeInterval) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
    }
}

/// Album art from somewhere other than Music, for tracks Music has none for.
public protocol CatalogArtworkLookup: Sendable {
    /// The image bytes, or nil when nothing matches closely enough to trust.
    /// Throws when the lookup itself failed, so it can be tried again later.
    func artwork(for query: CatalogQuery) async throws -> Data?
}

/// Album art from Apple's public catalogue, through the iTunes Search API.
///
/// Music often has no artwork for streamed songs that aren't in the library
/// (`URL track`s from autoplay): measured on 10 November, most read 0 artworks
/// for as long as they were watched. macOS's own Now Playing shows art for
/// them from the catalogue, so this asks the same catalogue. It sends the
/// artist, title and storefront, and nothing about the Mac or the listener.
public struct ITunesCatalogArtwork: CatalogArtworkLookup {
    public static let pixelSize = 600
    public static let maximumImageBytes = 2_000_000
    /// How far a catalogue track's length may be from Music's when the album
    /// names differ, as they do between a single and its album.
    public static let durationTolerance: TimeInterval = 3

    public var country: String
    private let session: URLSession

    public init(country: String = Locale.current.region?.identifier ?? "US") {
        self.country = country
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    public func artwork(for query: CatalogQuery) async throws -> Data? {
        let (data, response) = try await session.data(from: Self.searchURL(for: query, country: country))
        try Self.check(response)
        let songs = try JSONDecoder().decode(SearchResponse.self, from: data).results
        guard let match = Self.bestMatch(for: query, in: songs),
              let url = match.artworkUrl100.flatMap({ Self.artworkURL(from: $0) })
        else { return nil }
        let (image, imageResponse) = try await session.data(from: url)
        try Self.check(imageResponse)
        guard !image.isEmpty, image.count <= Self.maximumImageBytes else { return nil }
        return image
    }

    // MARK: Pieces, separately testable

    public struct Song: Decodable, Equatable, Sendable {
        public var kind: String?
        public var trackName: String?
        public var artistName: String?
        public var collectionName: String?
        public var trackTimeMillis: Int?
        public var artworkUrl100: String?
        /// The catalogue ID, as `TrackMetadata.catalogID`.
        public var trackId: Int?

        public init(kind: String? = "song", trackName: String?, artistName: String?, collectionName: String?,
                    trackTimeMillis: Int?, artworkUrl100: String?, trackId: Int? = nil) {
            self.kind = kind
            self.trackName = trackName
            self.artistName = artistName
            self.collectionName = collectionName
            self.trackTimeMillis = trackTimeMillis
            self.artworkUrl100 = artworkUrl100
            self.trackId = trackId
        }
    }

    struct SearchResponse: Decodable {
        var results: [Song]
    }

    public struct LookupError: Error, Equatable {
        public var status: Int
    }

    static func check(_ response: URLResponse) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw LookupError(status: status) }
    }

    /// `search?term=…&media=music&entity=song`, encoded by hand: URLComponents
    /// leaves `+` alone, which the server reads as a space.
    public static func searchURL(for query: CatalogQuery, country: String) -> URL {
        searchURL(term: "\(query.artist) \(withoutCredits(query.title))", limit: 25, country: country)
    }

    /// Every song of an album in one search: the lead artist and the album name.
    public static func albumSearchURL(artist: String, album: String, country: String) -> URL {
        let lead = artist.components(separatedBy: CharacterSet(charactersIn: ",&;")).first ?? artist
        let name = album.replacingOccurrences(of: #"\s+-\s+(single|ep)\s*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        return searchURL(term: "\(lead) \(name)", limit: 200, country: country)
    }

    static func searchURL(term rawTerm: String, limit: Int, country: String) -> URL {
        let term = rawTerm.replacingOccurrences(of: "&", with: " ").split(separator: " ").joined(separator: " ")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        func encode(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        let items = [("term", term), ("media", "music"), ("entity", "song"), ("limit", String(limit)), ("country", country)]
        let query = items.map { "\($0.0)=\(encode($0.1))" }.joined(separator: "&")
        return URL(string: "https://itunes.apple.com/search?\(query)")!
    }

    /// The same title and artist, and the same album or a length within
    /// `durationTolerance`. A matching album wins, then the closest length.
    public static func bestMatch(for query: CatalogQuery, in songs: [Song]) -> Song? {
        let title = normalized(query.title)
        let album = normalized(album: query.album)
        let candidates = songs.compactMap { song -> (song: Song, albumMatches: Bool, gap: TimeInterval)? in
            guard song.kind == nil || song.kind == "song",
                  let name = song.trackName, let artist = song.artistName,
                  normalized(name) == title, artistsMatch(query.artist, artist)
            else { return nil }
            let albumMatches = song.collectionName.map { normalized(album: $0) == album } ?? false
            let gap = song.trackTimeMillis.map { abs(Double($0) / 1000 - query.duration) } ?? .infinity
            guard albumMatches || gap <= durationTolerance else { return nil }
            return (song, albumMatches, gap)
        }
        return candidates.min { a, b in
            a.albumMatches != b.albumMatches ? a.albumMatches : a.gap < b.gap
        }?.song
    }

    /// The 600-pixel version of a catalogue thumbnail, from Apple's image host only.
    public static func artworkURL(from thumbnail: String) -> URL? {
        guard let source = URL(string: thumbnail), source.scheme == "https",
              let host = source.host()?.lowercased(), host == "mzstatic.com" || host.hasSuffix(".mzstatic.com")
        else { return nil }
        let sized = thumbnail.replacingOccurrences(of: #"/\d+x\d+bb\.(jpg|png|webp)$"#,
                                                   with: "/\(pixelSize)x\(pixelSize)bb.jpg", options: .regularExpression)
        return URL(string: sized)
    }

    // MARK: Matching

    /// Folded to lower case without accents or punctuation, with featured-artist
    /// credits dropped: Music and the catalogue put those in different places.
    static func normalized(_ text: String) -> String {
        let folded = withoutCredits(text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil))
            .replacingOccurrences(of: "&", with: " and ")
        return folded.split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
    }

    /// Also drops " - Single" and " - EP", which the catalogue adds to album names.
    static func normalized(album: String) -> String {
        normalized(album.replacingOccurrences(of: #"\s+-\s+(single|ep)\s*$"#, with: "", options: [.regularExpression, .caseInsensitive]))
    }

    static func withoutCredits(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s*[\(\[]\s*(feat|ft|featuring|with)\b\.?[^\)\]]*[\)\]]"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s+(feat|ft|featuring)\b\.?\s.*$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
    }

    /// The whole credit, or failing that the first-named artist on both sides
    /// ("Disclosure, Chris Lake & Leven Kali" against "Disclosure & Chris Lake").
    static func artistsMatch(_ a: String, _ b: String) -> Bool {
        if normalized(a) == normalized(b) { return true }
        let first = { (credit: String) -> String in
            let folded = credit.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            let lead = folded.components(separatedBy: CharacterSet(charactersIn: ",&;")).first ?? folded
            return normalized(lead.replacingOccurrences(of: #"\s+(x|and|with)\s.*$"#, with: "", options: .regularExpression))
        }
        let lead = first(a)
        return !lead.isEmpty && lead == first(b)
    }
}
