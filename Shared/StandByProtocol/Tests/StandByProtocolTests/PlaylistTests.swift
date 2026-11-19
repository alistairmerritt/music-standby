import Foundation
import Testing
@testable import StandByProtocol

@Suite struct PlaylistPlaceTests {
    private let place = PlaylistPlace(name: "Road Trip", cloudID: "pl.u-Zx9yW8vU7tS6r", count: 123, index: 39)

    @Test func validity() {
        #expect(place.isValid)
        #expect(!PlaylistPlace(name: "", count: 3, index: 0).isValid)
        #expect(!PlaylistPlace(name: "A", count: 0, index: 0).isValid)
        #expect(!PlaylistPlace(name: "A", count: 3, index: 3).isValid)
        #expect(!PlaylistPlace(name: "A", count: 3, index: -1).isValid)
        // A missing or odd Apple Music ID is only ignored (a six-song playlist, 17 November 2026).
        #expect(PlaylistPlace(name: "A", cloudID: "", count: 3, index: 0).isValid)
        #expect(PlaylistPlace(name: "A", cloudID: "", count: 3, index: 0).cloudID == nil)
        var odd = place
        odd.cloudID = String(repeating: "x", count: 65)
        #expect(odd.isValid && odd.knownCloudID == nil)
        #expect(place.knownCloudID == "pl.u-Zx9yW8vU7tS6r")
        #expect(!PlaylistPlace(name: String(repeating: "x", count: 257), count: 3, index: 0).isValid)
    }

    @Test func locatesTheSongWhereItIsOrClosest() {
        let ids: [String?] = ["1", "2", "3", nil, "2", "5"]
        #expect(PlaylistPlace(name: "P", count: 6, index: 1).locate("2", in: ids) == 1)
        // Moved by an edit on the other device: the nearest copy wins.
        #expect(PlaylistPlace(name: "P", count: 6, index: 3).locate("2", in: ids) == 4)
        #expect(PlaylistPlace(name: "P", count: 6, index: 0).locate("5", in: ids) == 5)
        #expect(PlaylistPlace(name: "P", count: 6, index: 2).locate("9", in: ids) == nil)
        // An index past the end of a shorter playlist still finds the song.
        #expect(PlaylistPlace(name: "P", count: 9, index: 8).locate("3", in: ids) == 2)
    }

    @Test func shuffledDefaultsToNo() {
        #expect(!place.isShuffled)
        #expect(PlaylistPlace(name: "P", count: 2, index: 0, shuffled: true).isShuffled)
    }

    @Test func playStationCarriesAPausedPositionOverTheWire() throws {
        let command = RemoteCommand.playStation(seededBy: "1", position: 6.5, title: "Song", positionIsPaused: true,
                                                issuedAt: Date(timeIntervalSince1970: 1_794_207_600))
        let decoded = try StandByWire.makeDecoder().decode(RemoteCommand.self, from: try StandByWire.makeEncoder().encode(command))
        #expect(decoded.positionIsPaused == true)
        let plain = try StandByWire.makeEncoder().encode(RemoteCommand.playStation(seededBy: "1"))
        #expect(!String(decoding: plain, as: UTF8.self).contains("positionIsPaused"))
    }

    @Test func playStationCarriesThePlaylistOverTheWire() throws {
        let command = RemoteCommand.playStation(seededBy: "576670459", position: 61.5, title: "Song Forty", playlist: place,
                                                issuedAt: Date(timeIntervalSince1970: 1_794_207_600))
        let data = try StandByWire.makeEncoder().encode(command)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains(#""playlist":{"#))
        #expect(json.contains(#""name":"Road Trip""#))
        #expect(try StandByWire.makeDecoder().decode(RemoteCommand.self, from: data) == command)
        #expect(command.hasRequiredValue)
    }

    @Test func playStationCarriesAnAlbumOverTheWire() throws {
        let album = AlbumPlace(title: "Made-Up Album", artist: "Made-Up Band", count: 25, index: 9, shuffled: true)
        #expect(album.isValid && album.isShuffled)
        #expect(!AlbumPlace(title: "", count: 3, index: 0).isValid)
        #expect(!AlbumPlace(title: "A", count: 3, index: 3).isValid)
        let command = RemoteCommand.playStation(seededBy: "1", position: 5, title: "Song", album: album, issuedAt: Date(timeIntervalSince1970: 1_794_207_600))
        let data = try StandByWire.makeEncoder().encode(command)
        #expect(String(decoding: data, as: UTF8.self).contains(#""album":{"#))
        #expect(try StandByWire.makeDecoder().decode(RemoteCommand.self, from: data) == command)
    }

    @Test func shuffleGoesWithAnAppleMusicSource() throws {
        let message = PlaybackMessage(revision: 3, state: .playing, elapsedTime: 1, capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                      track: nil, canGoNext: true, canGoPrevious: true, fromAppleMusic: true, shuffled: true)
        let back = try JSONDecoder().decode(PlaybackMessage.self, from: JSONEncoder().encode(message))
        #expect(back.shuffled == true && back.fromAppleMusic == true)
    }

    @Test func stationsLibraryShuffleAndRepeatGoOverTheWire() throws {
        #expect(StationPlace(id: "ra.u-bd06bafc2374e5051abb70ff757aa95f", name: "My Station").isValid)
        #expect(!StationPlace(id: "pl.123", name: "x").isValid)
        #expect(!StationPlace(id: "ra.1/../2", name: "x").isValid)
        let command = RemoteCommand.playStation(seededBy: "1", position: 5, title: "Song", station: StationPlace(id: "ra.978194965", name: "Radio"),
                                                shuffledLibrary: true, repeatMode: .all, issuedAt: Date(timeIntervalSince1970: 1_794_207_600))
        let data = try StandByWire.makeEncoder().encode(command)
        #expect(try StandByWire.makeDecoder().decode(RemoteCommand.self, from: data) == command)
        #expect(String(decoding: data, as: UTF8.self).contains(#""repeatMode":"all""#))

        let message = PlaybackMessage(revision: 1, state: .playing, elapsedTime: 1, capturedAt: Date(timeIntervalSince1970: 1_794_207_600),
                                      track: Fixture.losingMyEdge, canGoNext: true, canGoPrevious: true,
                                      album: AlbumPlace(title: "A", count: 9, index: 2, shuffled: true), shuffledLibrary: false,
                                      fromAppleMusic: true, repeatMode: .one)
        let back = try StandByWire.makeDecoder().decode(PlaybackMessage.self, from: StandByWire.makeEncoder().encode(message))
        #expect(back == message)
        #expect(PlaylistPlace(name: "P", count: 3, index: 1, addedToLibrary: true).addedToLibrary == true)
    }

    @Test func aCommandWithoutAPlaylistLeavesItOut() throws {
        let data = try StandByWire.makeEncoder().encode(RemoteCommand.playStation(seededBy: "1"))
        #expect(!String(decoding: data, as: UTF8.self).contains("playlist"))
    }

    @Test func playbackCarriesThePlaylistAndOlderJSONStillDecodes() throws {
        let message = PlaybackMessage(revision: 4, state: .playing, elapsedTime: 12, capturedAt: Date(timeIntervalSince1970: 1_794_207_600),
                                      track: Fixture.losingMyEdge, canGoNext: true, canGoPrevious: true, playlist: place)
        let data = try StandByWire.makeEncoder().encode(message)
        #expect(try StandByWire.makeDecoder().decode(PlaybackMessage.self, from: data) == message)

        var older = message
        older.playlist = nil
        let olderData = try StandByWire.makeEncoder().encode(older)
        #expect(!String(decoding: olderData, as: UTF8.self).contains("playlist"))
        #expect(try StandByWire.makeDecoder().decode(PlaybackMessage.self, from: olderData).playlist == nil)
    }
}
