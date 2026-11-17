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
