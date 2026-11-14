import Foundation
import Testing
@testable import CompanionCore

/// A catalogue that answers the same way every time and remembers each query.
actor FakeCatalogue: CatalogArtworkLookup {
    enum Answer: Sendable {
        case image(Data)
        case noMatch
        case failure
    }

    struct Offline: Error {}

    private let answer: Answer
    private(set) var queries: [CatalogQuery] = []

    init(_ answer: Answer) { self.answer = answer }

    func artwork(for query: CatalogQuery) async throws -> Data? {
        queries.append(query)
        switch answer {
        case .image(let data): return data
        case .noMatch: return nil
        case .failure: throw Offline()
        }
    }
}

/// `ITunesCatalogArtwork`'s matching. A wrong cover is worse than none, so
/// most of these check what is refused.
@Suite struct CatalogArtworkTests {
    typealias Catalogue = ITunesCatalogArtwork

    private func song(_ title: String, by artist: String, on album: String, seconds: Double?,
                      art: String = "https://is1-ssl.mzstatic.com/image/thumb/Music/v4/aa/bb/x.jpg/100x100bb.jpg") -> Catalogue.Song {
        Catalogue.Song(trackName: title, artistName: artist, collectionName: album,
                       trackTimeMillis: seconds.map { Int($0 * 1000) }, artworkUrl100: art)
    }

    private let query = CatalogQuery(title: "Am I Wrong (feat. ScHoolboy Q)", artist: "Anderson .Paak",
                                     album: "Malibu", duration: 251)

    @Test func theSameSongOnTheSameAlbumMatches() {
        let match = Catalogue.bestMatch(for: query, in: [
            song("Am I Wrong (feat. ScHoolboy Q)", by: "Anderson .Paak", on: "Malibu", seconds: 251.4),
        ])
        #expect(match?.collectionName == "Malibu")
    }

    @Test func featuredCreditsAndAccentsDoNotMatter() {
        let q = CatalogQuery(title: "Café (feat. Someone)", artist: "Beyoncé", album: "Album", duration: 200)
        #expect(Catalogue.bestMatch(for: q, in: [song("CAFE", by: "Beyonce", on: "Album", seconds: nil)]) != nil)
    }

    @Test func aDifferentAlbumNeedsTheSameLength() {
        let single = song("Am I Wrong (feat. ScHoolboy Q)", by: "Anderson .Paak", on: "Am I Wrong - Single", seconds: 252)
        let remix = song("Am I Wrong (feat. ScHoolboy Q)", by: "Anderson .Paak", on: "Remixes", seconds: 330)
        #expect(Catalogue.bestMatch(for: query, in: [single])?.collectionName == "Am I Wrong - Single")
        #expect(Catalogue.bestMatch(for: query, in: [remix]) == nil, "77 s longer: another version, and maybe another cover")
    }

    @Test func theSingleSuffixCountsAsTheSameAlbum() {
        let q = CatalogQuery(title: "Nightrider (feat. Freddie Gibbs)", artist: "Tom Misch & Yussef Dayes",
                             album: "Nightrider - Single", duration: 300)
        #expect(Catalogue.bestMatch(for: q, in: [song("Nightrider", by: "Tom Misch & Yussef Dayes", on: "Nightrider", seconds: nil)]) != nil)
    }

    @Test func theAlbumWinsOverACloserLength() {
        let match = Catalogue.bestMatch(for: query, in: [
            song("Am I Wrong (feat. ScHoolboy Q)", by: "Anderson .Paak", on: "Best Of", seconds: 251),
            song("Am I Wrong (feat. ScHoolboy Q)", by: "Anderson .Paak", on: "Malibu", seconds: 253),
        ])
        #expect(match?.collectionName == "Malibu")
    }

    @Test func anotherArtistsSongOfTheSameNameIsRefused() {
        let q = CatalogQuery(title: "Happy Man", artist: "Jungle", album: "Loving In Stereo", duration: 200)
        #expect(Catalogue.bestMatch(for: q, in: [song("Happy Man", by: "Hall & Oates", on: "Loving In Stereo", seconds: 200)]) == nil)
    }

    @Test func anotherSongByTheArtistIsRefused() {
        #expect(Catalogue.bestMatch(for: query, in: [song("Come Down", by: "Anderson .Paak", on: "Malibu", seconds: 251)]) == nil)
    }

    @Test func aCreditListedDifferentlyStillMatchesOnTheFirstArtist() {
        let q = CatalogQuery(title: "one2three", artist: "Disclosure, Chris Lake & Leven Kali", album: "one2three", duration: 210)
        #expect(Catalogue.bestMatch(for: q, in: [song("one2three", by: "Disclosure & Chris Lake", on: "one2three", seconds: nil)]) != nil)
        #expect(Catalogue.bestMatch(for: q, in: [song("one2three", by: "Chris Lake", on: "one2three", seconds: nil)]) == nil)
    }

    @Test func videosAndOtherKindsAreIgnored() {
        var video = song("Am I Wrong (feat. ScHoolboy Q)", by: "Anderson .Paak", on: "Malibu", seconds: 251)
        video.kind = "music-video"
        #expect(Catalogue.bestMatch(for: query, in: [video]) == nil)
    }

    @Test func theThumbnailIsAskedForAt600Pixels() {
        let url = Catalogue.artworkURL(from: "https://is1-ssl.mzstatic.com/image/thumb/Music126/v4/ab/cd/ef/0123.jpg/100x100bb.jpg")
        #expect(url?.absoluteString == "https://is1-ssl.mzstatic.com/image/thumb/Music126/v4/ab/cd/ef/0123.jpg/600x600bb.jpg")
    }

    @Test func artworkComesOnlyFromApplesImageHostOverHTTPS() {
        #expect(Catalogue.artworkURL(from: "http://is1-ssl.mzstatic.com/a/100x100bb.jpg") == nil)
        #expect(Catalogue.artworkURL(from: "https://mzstatic.com.example.net/a/100x100bb.jpg") == nil)
        #expect(Catalogue.artworkURL(from: "https://example.com/a/100x100bb.jpg") == nil)
    }

    @Test func theSearchCarriesOnlyArtistTitleAndStorefront() throws {
        let url = Catalogue.searchURL(for: CatalogQuery(title: "Nightrider (feat. Freddie Gibbs)", artist: "Tom Misch & Yussef Dayes",
                                                        album: "Private album name", duration: 300), country: "AU")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(url.host() == "itunes.apple.com")
        #expect(values["term"] == "Tom Misch Yussef Dayes Nightrider")
        #expect(values["entity"] == "song")
        #expect(values["country"] == "AU")
        #expect(!url.absoluteString.contains("Private"), "the album isn't sent")
    }

    @Test func aPlusSignInATitleIsEncoded() {
        let url = Catalogue.searchURL(for: CatalogQuery(title: "1+1", artist: "Beyoncé", album: "4", duration: 270), country: "US")
        #expect(url.absoluteString.contains("1%2B1"))
    }
}
