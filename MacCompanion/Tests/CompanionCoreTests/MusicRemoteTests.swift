import Foundation
import os
import StandByProtocol
import Testing
@testable import CompanionCore

/// Music as DACP answers it, built from the shapes seen from the real Music
/// on 12 November 2026 (with made-up songs).
private enum Fake {
    static func node(_ tag: String, _ children: Data...) -> Data { DMAPNode.encode(tag, children: children) }
    static func text(_ tag: String, _ value: String) -> Data { DMAPNode.encode(tag, string: value) }
    static func u32(_ tag: String, _ value: UInt32) -> Data { DMAPNode.encode(tag, uint32: value) }
    static func u64(_ tag: String, _ value: UInt64) -> Data { DMAPNode.encode(tag, uint64: value) }

    static let login = node("mlog", u32("mstt", 200), u32("mlid", 850_003_812))
    static let databases = node("avdb", u32("mstt", 200), node("mlcl", node("mlit", u32("miid", 61), text("minm", "Library"))))
    /// Two library songs: the current one and the next.
    static let library = node("adbs", u32("mstt", 200), node("mlcl",
        node("mlit", u32("miid", 40798), u64("mper", 0x71F8_D700_86B0_C8D9), u32("aeSI", 1_102_360_418)),
        node("mlit", u32("miid", 40778), u64("mper", 0x1907_0902_329B_99DF), u32("aeSI", 1_102_359_994)),
        node("mlit", u32("miid", 1), u64("mper", 1), u32("aeSI", 0))))   // no catalogue ID: left out
    static func spec(item: UInt32) -> Data {
        DMAPNode.encode("ceQs", Data([0, 0, 0, 0x3D, 0, 0, 0xC5, 0x86, 0, 0, 0xD2, 0x81]) + withUnsafeBytes(of: item.bigEndian) { Data($0) })
    }
    /// Section headers first, as Music sends them, then the songs.
    static let queue = node("ceQR", u32("mstt", 200), node("mlcl",
        node("ceQS", node("mlit", u32("ceQk", 0x6D61_696E), u32("ceQm", 100))),
        node("mlit", spec(item: 40778), text("ceQn", "Lady Divine"), text("ceQr", "Alela Diane"), u32("astm", 312_308)),
        node("mlit", spec(item: 99999), text("ceQn", "Not in the library"), text("ceQr", "Nobody"), u32("astm", 1000))))
    static func playing(_ title: String, by artist: String) -> Data {
        node("cmst", u32("mstt", 200), u32("cmsr", 7), u32("caps", 4), text("cann", title), text("cana", artist), text("canl", "Album"))
    }
    static let artwork = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
}

/// Answers by path, counting what was asked.
private final class FakeDACP: LocalHTTP, Sendable {
    let answers: OSAllocatedUnfairLock<[(prefix: String, status: Int, body: Data)]>
    let asked = OSAllocatedUnfairLock<[String]>(initialState: [])

    init(_ answers: [(String, Int, Data)]) {
        self.answers = OSAllocatedUnfairLock(initialState: answers.map { ($0.0, $0.1, $0.2) })
    }

    func get(port: Int, path: String) async throws -> (status: Int, body: Data) {
        asked.withLock { $0.append(path) }
        let answer = answers.withLock { list -> (Int, Data)? in
            guard let index = list.firstIndex(where: { path.hasPrefix($0.prefix) }) else { return nil }
            return (list[index].status, list[index].body)
        }
        return answer ?? (404, Data())
    }

    func setAnswer(_ prefix: String, _ status: Int, _ body: Data) {
        answers.withLock { list in
            list.removeAll { $0.prefix == prefix }
            list.insert((prefix, status, body), at: 0)
        }
    }

    func count(_ prefix: String) -> Int { asked.withLock { $0.filter { $0.hasPrefix(prefix) }.count } }
}

private func song(_ persistentID: String) -> MusicTrack {
    MusicTrack(title: "Song", artist: "Artist", album: "Album", duration: 200, persistentID: persistentID)
}

private let pairing = MusicRemotePairing(guid: "0123456789ABCDEF", serviceName: "8C8A8C27179DD8F0")

private func client(_ music: FakeDACP, now: @escaping @Sendable () -> Date = { Date() }) -> MusicRemoteClient {
    MusicRemoteClient(pairing: pairing, http: music, locate: { $0 == pairing.serviceName ? 58003 : nil }, now: now)
}

private func standardMusic() -> FakeDACP {
    FakeDACP([("/login", 200, Fake.login), ("/databases/61/items", 200, Fake.library), ("/databases", 200, Fake.databases),
               ("/ctrl-int/1/playqueue-contents", 200, Fake.queue)])
}

@Suite struct DMAPTests {
    @Test func nestedTagsRoundTrip() throws {
        let data = Fake.node("cmst", Fake.u32("caps", 4), Fake.text("cann", "Song"), Fake.u64("asai", 258_389_302_050_206_131))
        let root = try #require(DMAPNode.parse(data).first)
        #expect(root.tag == "cmst")
        #expect(root.first("caps")?.integer == 4)
        #expect(root.first("cann")?.string == "Song")
        #expect(root.first("asai")?.integer == 258_389_302_050_206_131)
        #expect(DMAPNode.parse(Data([0x6D, 0x6C, 0x69, 0x64, 0, 0, 0, 9, 1])).isEmpty, "a value cut short is dropped, not read past")
    }
}

@Suite struct MusicRemotePairerTests {
    @Test func readsMusicsServiceNameFromThePairRequest() {
        let request = "GET /pair?pairingcode=6A3F0C1D2E4B5A69788796A5B4C3D2E1&servicename=8C8A8C27179DD8F0 HTTP/1.1\r\nHost: x\r\n\r\n"
        #expect(MusicRemotePairer.serviceName(inPairRequest: request) == "8C8A8C27179DD8F0")
        #expect(MusicRemotePairer.serviceName(inPairRequest: "GET /other?servicename=X HTTP/1.1\r\n\r\n") == nil)
        #expect(MusicRemotePairer.serviceName(inPairRequest: "GET /pair?pairingcode=1 HTTP/1.1\r\n\r\n") == nil)
        #expect(MusicRemotePairer.serviceName(inPairRequest: "") == nil)
    }

    @Test func answersWithItsGUIDNameAndType() throws {
        let reply = try #require(DMAPNode.parse(MusicRemotePairer.pairResponse(guid: "0123456789ABCDEF", name: "Second Chair")).first)
        #expect(reply.tag == "cmpa")
        #expect(reply.first("cmpg")?.value == Data([0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF]))
        #expect(reply.first("cmnm")?.string == "Second Chair")
        #expect(reply.first("cmty")?.string == "iPhone")
        let pairer = MusicRemotePairer()
        #expect(pairer.code.count == 4 && pairer.code.allSatisfy(\.isNumber))
    }
}

@Suite struct MusicRemoteClientTests {
    @Test func findsTheCatalogueIDAndUpNext() async throws {
        let music = standardMusic()
        let queue = try #require(await client(music).queue(current: song("71f8d70086b0c8d9")))
        #expect(queue.catalogID == "1102360418", "matched case-insensitively on the persistent ID")
        #expect(queue.upNext == [QueuedTrack(catalogID: "1102359994", title: "Lady Divine", artist: "Alela Diane", duration: 312.308),
                                 QueuedTrack(catalogID: nil, title: "Not in the library", artist: "Nobody", duration: 1)])
        #expect(music.asked.withLock { $0 }.allSatisfy { $0.hasPrefix("/login") || $0.contains("session-id=850003812") })
    }

    @Test func saysUnpairedWhenMusicHasForgottenThePairing() async {
        let music = FakeDACP([("/login", 503, Data())])
        let remote = client(music)
        #expect(await remote.queue(current: song("71F8D70086B0C8D9")) == nil)
        #expect(await remote.status == .unpaired)
    }

    @Test func logsInAgainWhenMusicLetsTheSessionGo() async throws {
        let music = standardMusic()
        let remote = client(music)
        _ = await remote.queue(current: song("71F8D70086B0C8D9"))
        music.setAnswer("/ctrl-int/1/playqueue-contents", 403, Data())
        let failed = await remote.queue(current: song("71F8D70086B0C8D9"))
        #expect(failed == nil, "still 403 after logging in again: give up for this read")
        #expect(music.count("/login") == 2)
        music.setAnswer("/ctrl-int/1/playqueue-contents", 200, Fake.queue)
        #expect(await remote.queue(current: song("71F8D70086B0C8D9"))?.upNext.count == 2)
        #expect(await remote.status == .connected)
    }

    @Test func readsTheLibraryAtMostOnceAMinuteForUnknownSongs() async {
        let clock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1000))
        let music = standardMusic()
        let remote = client(music, now: { clock.withLock { $0 } })
        for _ in 0..<3 { _ = await remote.queue(current: song("AAAAAAAAAAAAAAAA")) }   // the radio: not in the library
        #expect(music.count("/databases/61/items") == 1)
        clock.withLock { $0 += 61 }
        _ = await remote.queue(current: song("AAAAAAAAAAAAAAAA"))
        #expect(music.count("/databases/61/items") == 2)
        _ = await remote.queue(current: song("71F8D70086B0C8D9"))   // known: no read
        #expect(music.count("/databases/61/items") == 2)
    }

    @Test func takesMusicsArtworkWhenItsPlayingTheSameSong() async {
        let music = FakeDACP([("/login", 200, Fake.login), ("/ctrl-int/1/playstatusupdate", 200, Fake.playing("SONG", by: "artist")),
                              ("/ctrl-int/1/nowplayingartwork", 200, Fake.artwork)])
        #expect(await client(music).artwork(for: song("71F8D70086B0C8D9")) == Fake.artwork, "matched ignoring case")
        #expect(music.asked.withLock { $0 }.contains { $0.hasPrefix("/ctrl-int/1/nowplayingartwork?mw=600&mh=600&session-id=850003812") })
    }

    @Test func leavesArtworkAloneWhenMusicHasMovedOn() async {
        let music = FakeDACP([("/login", 200, Fake.login), ("/ctrl-int/1/playstatusupdate", 200, Fake.playing("Next Song", by: "Artist")),
                              ("/ctrl-int/1/nowplayingartwork", 200, Fake.artwork)])
        #expect(await client(music).artwork(for: song("71F8D70086B0C8D9")) == nil)
        #expect(music.count("/ctrl-int/1/nowplayingartwork") == 0, "never asked: it would be the next song's cover")
    }

    @Test func hasNoArtworkWhenMusicHasNone() async {
        let music = FakeDACP([("/login", 200, Fake.login), ("/ctrl-int/1/playstatusupdate", 200, Fake.playing("Song", by: "Artist"))])
        let remote = client(music)
        #expect(await remote.artwork(for: song("71F8D70086B0C8D9")) == nil, "Music answers 404")
        #expect(await remote.artwork(for: song("71F8D70086B0C8D9")) == nil)
        #expect(music.count("/login") == 1, "a 404 doesn't cost the session")
    }

    @Test func isUnreachableWhenMusicIsntAdvertised() async {
        let remote = MusicRemoteClient(pairing: pairing, http: standardMusic(), locate: { _ in nil })
        #expect(await remote.queue(current: nil) == nil)
        #expect(await remote.status == .unreachable)
    }
}

@Suite struct PublisherQueueTests {
    private let track = MusicTrack(title: "Late Night Tales", artist: "Jon Hopkins", album: "Late Night Tales", duration: 4337.5,
                                   persistentID: "71F8D70086B0C8D9")
    private func snap(_ t: Double = 1000) -> MusicSnapshot {
        MusicSnapshot(state: .playing, position: 10, capturedAt: Date(timeIntervalSince1970: t), track: track)
    }

    @Test func carriesTheCatalogueIDAndUpNextButUpNextAloneSendsNothing() throws {
        var p = PlaybackPublisher(revisions: RevisionCounter(lastPersisted: nil, now: Date(timeIntervalSince1970: 1000)))
        let upNext = [QueuedTrack(catalogID: "1102359994", title: "Lady Divine", artist: "Alela Diane", duration: 312)]
        let sent = p.ingest(snap(), artworkID: nil, queue: RemoteQueue(catalogID: "1102360418", upNext: upNext))
        let m = try #require(sent)
        #expect(m.track?.catalogID == "1102360418")
        #expect(m.upNext == upNext)
        let edited = RemoteQueue(catalogID: "1102360418", upNext: upNext + upNext)
        #expect(p.ingest(snap(1001), artworkID: nil, queue: edited) == nil, "a queue edit alone costs no push")
        #expect(p.ingest(snap(1001), artworkID: nil, queue: nil) != nil, "losing the catalogue ID is a change")
    }
}

/// The iTunes Search API, answering album searches from a fixed catalogue.
private final class FakeSearchAPI: Sendable {
    let searches = OSAllocatedUnfairLock<[String]>(initialState: [])
    let songs: [String: [ITunesCatalogArtwork.Song]]
    init(_ songs: [String: [ITunesCatalogArtwork.Song]]) { self.songs = songs }

    func fetch(_ url: URL) async throws -> Data {
        let term = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "term" }?.value ?? ""
        searches.withLock { $0.append(term) }
        let results = songs.first { term.localizedCaseInsensitiveContains($0.key) }?.value ?? []
        let json = results.map { s in
            #"{"kind":"song","trackName":"\#(s.trackName ?? "")","artistName":"\#(s.artistName ?? "")","collectionName":"\#(s.collectionName ?? "")","trackTimeMillis":\#(s.trackTimeMillis ?? 0),"trackId":\#(s.trackId ?? 0)}"#
        }
        return Data(#"{"results":[\#(json.joined(separator: ","))]}"#.utf8)
    }
}

private func catalogueSong(_ title: String, _ millis: Int, _ id: Int, album: String = "Flowers") -> ITunesCatalogArtwork.Song {
    ITunesCatalogArtwork.Song(trackName: title, artistName: "Durand Jones & The Indications", collectionName: album,
                              trackTimeMillis: millis, artworkUrl100: nil, trackId: id)
}

@Suite struct CatalogIDTests {
    private let flowers = FakeSearchAPI(["Flowers": [
        catalogueSong("Paradise", 301_480, 1_700_000_001), catalogueSong("Lovers' Holiday", 205_707, 1_700_000_002),
        catalogueSong("Flower Moon", 296_000, 1_700_000_004),
    ]])

    private func query(_ title: String, _ seconds: Double, album: String = "Flowers") -> CatalogQuery {
        CatalogQuery(title: title, artist: "Durand Jones & The Indications & Aaron Frazer", album: album, duration: seconds)
    }

    @Test func findsAWholeAlbumInOneSearchAndRemembersIt() async {
        let catalogue = flowers
        let lookup = ITunesCatalogIDs(country: "AU", fetch: { try await catalogue.fetch($0) })
        let ids = await lookup.catalogIDs(for: [query("Paradise", 301.5), query("Lovers' Holiday", 205.7), query("Not on it", 100)])
        #expect(ids == ["1700000001", "1700000002", nil])
        #expect(catalogue.searches.withLock { $0 } == ["Durand Jones Flowers"], "one search, by lead artist and album")
        _ = await lookup.catalogIDs(for: [query("Paradise", 301.5), query("Flower Moon", 296)])
        #expect(catalogue.searches.withLock { $0.count } == 1, "the album is kept")
    }

    @Test func searchesAtMostFourAlbumsACallAndRetriesMissesLater() async {
        let catalogue = FakeSearchAPI([:])
        let clock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1000))
        let lookup = ITunesCatalogIDs(country: "AU", fetch: { try await catalogue.fetch($0) }, now: { clock.withLock { $0 } })
        let six = (1...6).map { query("Song \($0)", 200, album: "Album \($0)") }
        #expect(await lookup.catalogIDs(for: six).allSatisfy { $0 == nil })
        #expect(catalogue.searches.withLock { $0.count } == ITunesCatalogIDs.searchesPerCall)
        _ = await lookup.catalogIDs(for: six)
        #expect(catalogue.searches.withLock { $0.count } == 6, "the next call takes the rest; misses aren't searched again")
        clock.withLock { $0 += ITunesCatalogIDs.missRetry + 1 }
        _ = await lookup.catalogIDs(for: Array(six.prefix(1)))
        #expect(catalogue.searches.withLock { $0.count } == 7, "a miss is tried again after half an hour")
    }
}

private struct FixedRemote: MusicRemoteReading {
    let answer: RemoteQueue
    func queue(current track: MusicTrack?) async -> RemoteQueue? { answer }
}

private actor ListedLookup: CatalogIDLookup {
    private(set) var asked: [CatalogQuery] = []
    func catalogIDs(for queries: [CatalogQuery]) async -> [String?] {
        asked += queries
        return queries.map { $0.title == "Unknown" ? nil : "id:\($0.title)" }
    }
}

@Suite struct CatalogFillingRemoteTests {
    @Test func fillsTheCurrentSongAndUpNextWhereMusicGaveNoID() async throws {
        let remote = FixedRemote(answer: RemoteQueue(catalogID: nil, upNext: [
            QueuedTrack(catalogID: "1102359994", title: "Lady Divine", artist: "Alela Diane", album: "LNT", duration: 312),
            QueuedTrack(catalogID: nil, title: "Paradise", artist: "Durand Jones", album: "Flowers", duration: 301),
            QueuedTrack(catalogID: nil, title: "Unknown", artist: "Nobody", album: nil, duration: 10),
        ]))
        let lookup = ListedLookup()
        let current = MusicTrack(title: "Flowers", artist: "Durand Jones", album: "Flowers", duration: 250, persistentID: "64E7403688CA3632")
        let queue = try #require(await CatalogFillingRemote(remote: remote, lookup: lookup).queue(current: current))
        #expect(queue.catalogID == "id:Flowers")
        #expect(queue.upNext.map(\.catalogID) == ["1102359994", "id:Paradise", nil])
        #expect(await lookup.asked.map(\.title) == ["Flowers", "Paradise", "Unknown"], "songs Music already identified aren't looked up")
    }

    @Test func asksNothingWhenMusicIdentifiedEverything() async {
        let remote = FixedRemote(answer: RemoteQueue(catalogID: "1", upNext: [QueuedTrack(catalogID: "2", title: "A", artist: "B", duration: 1)]))
        let lookup = ListedLookup()
        _ = await CatalogFillingRemote(remote: remote, lookup: lookup).queue(current: nil)
        #expect(await lookup.asked.isEmpty)
    }
}
