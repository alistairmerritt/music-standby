import Foundation
import Testing
@testable import StandByProtocol

private func message(revision: UInt64 = 1, state: PlaybackState = .playing, elapsed: TimeInterval = 10,
                     at seconds: TimeInterval = 1000, track: TrackMetadata? = Fixture.losingMyEdge,
                     session: UUID? = Fixture.sessionID) -> PlaybackMessage {
    PlaybackMessage(revision: revision, state: state, elapsedTime: elapsed, capturedAt: Date(timeIntervalSince1970: seconds),
                    track: track, canGoNext: track != nil, canGoPrevious: track != nil, listeningSessionID: session)
}

@Suite struct WireTests {
    @Test func datesUseMillisecondISO8601InUTC() {
        let date = Date(timeIntervalSince1970: 1_794_207_600.25)
        #expect(StandByWire.formatDate(date) == "2026-11-09T07:00:00.250Z")
    }

    @Test func decoderAcceptsDatesWithAndWithoutFraction() {
        #expect(StandByWire.parseDate("2026-11-08T08:00:00Z") == Date(timeIntervalSince1970: 1_794_124_800))
        #expect(StandByWire.parseDate("2026-11-08T08:00:00.500Z") == Date(timeIntervalSince1970: 1_794_124_800.5))
        #expect(StandByWire.parseDate("1794124800") == nil)
    }

    @Test func decoderRejectsNumericDates() {
        let json = #"{"id":"5C1F7A9E-2B4D-4C61-8E3F-0A9B8C7D6E5F","kind":"play","issuedAt":1794124800}"#
        #expect(throws: DecodingError.self) { try StandByWire.makeDecoder().decode(RemoteCommand.self, from: Data(json.utf8)) }
    }

    /// A clock reading has sub-millisecond precision that the wire drops.
    @Test func wirePrecisionMakesAMessageSurviveARoundTrip() throws {
        let raw = Date(timeIntervalSince1970: 1_794_207_600.123_456_7)
        var m = PlaybackMessage(revision: 1, state: .playing, elapsedTime: 3, capturedAt: raw, track: nil, canGoNext: false, canGoPrevious: false)
        let decoder = StandByWire.makeDecoder()
        let encoder = StandByWire.makeEncoder()
        #expect(try decoder.decode(PlaybackMessage.self, from: encoder.encode(m)) != m)
        m.capturedAt = StandByWire.wirePrecision(raw)
        #expect(try decoder.decode(PlaybackMessage.self, from: encoder.encode(m)) == m)
        #expect(abs(m.capturedAt.timeIntervalSince(raw)) < 0.001)
        #expect(StandByWire.wirePrecision(m.capturedAt) == m.capturedAt)
    }

    @Test func wirePrecisionIsExactForAnyClockReading() throws {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<20_000 {
            let raw = Date(timeIntervalSince1970: Double.random(in: 0..<4_102_444_800, using: &generator))
            let kept = StandByWire.wirePrecision(raw)
            let text = StandByWire.formatDate(kept)
            #expect(StandByWire.parseDate(text) == kept, "\(raw.timeIntervalSince1970) → \(text)")
            #expect(StandByWire.formatDate(raw) == text)
            #expect(abs(kept.timeIntervalSince(raw)) <= 0.0005 + 1e-6)
        }
    }

    @Test func fractionsOfAnyLengthParse() {
        #expect(StandByWire.parseDate("2026-11-08T08:00:00.5Z") == Date(timeIntervalSince1970: 1_794_124_800.5))
        #expect(StandByWire.parseDate("2026-11-08T08:00:00.123456Z") == Date(timeIntervalSince1970: 1_794_124_800.123))
        #expect(StandByWire.parseDate("2026-11-08T08:00:00.Z") == nil)
        #expect(StandByWire.formatDate(Date(timeIntervalSince1970: -0.25)) == "1969-12-31T23:59:59.750Z")
    }

    @Test func messageRoundTripsThroughWireCoders() throws {
        var original = message()
        original.capturedAt = Date(timeIntervalSince1970: 1_794_207_600.125)
        let data = try StandByWire.makeEncoder().encode(original)
        #expect(try StandByWire.makeDecoder().decode(PlaybackMessage.self, from: data) == original)
    }
}

@Suite struct PlaybackMessageTests {
    /// The iOS app's temporary contract: no `state`, a bare `isPlaying`.
    @Test func decodesTemporaryContract() throws {
        let decoded = try StandByWire.makeDecoder().decode(PlaybackMessage.self, from: Fixture.data("legacy-playback-message"))
        #expect(decoded.state == .paused)
        #expect(decoded.revision == 42)
        #expect(decoded.track?.artworkID == "a1")
        #expect(decoded.listeningSessionID == nil)
    }

    @Test func legacyInitialiserDerivesState() {
        let date = Date(timeIntervalSince1970: 0)
        let t = Fixture.losingMyEdge
        #expect(PlaybackMessage(revision: 1, isPlaying: true, elapsedTime: 0, capturedAt: date, track: t, canGoNext: true, canGoPrevious: true).state == .playing)
        #expect(PlaybackMessage(revision: 1, isPlaying: false, elapsedTime: 0, capturedAt: date, track: t, canGoNext: true, canGoPrevious: true).state == .paused)
        #expect(PlaybackMessage(revision: 1, isPlaying: false, elapsedTime: 0, capturedAt: date, track: nil, canGoNext: false, canGoPrevious: false).state == .stopped)
    }

    @Test func stateWinsOverIsPlayingWhenTheyDisagree() throws {
        let json = #"{"revision":1,"state":"paused","isPlaying":true,"elapsedTime":0,"capturedAt":"2026-11-08T08:00:00Z","canGoNext":false,"canGoPrevious":false}"#
        let decoded = try StandByWire.makeDecoder().decode(PlaybackMessage.self, from: Data(json.utf8))
        #expect(decoded.state == .paused)
        #expect(!decoded.isPlaying)
    }

    @Test func isPlayingIsAlwaysEncodedAndConsistent() throws {
        for state in PlaybackState.allCases {
            let data = try StandByWire.makeEncoder().encode(message(state: state))
            let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object["isPlaying"] as? Bool == (state == .playing))
            #expect(object["state"] as? String == state.rawValue)
        }
    }

    @Test func missingTrackArtworkAndSessionAreOmitted() throws {
        let data = try StandByWire.makeEncoder().encode(message(state: .notRunning, track: nil, session: nil))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["track"] == nil)
        #expect(object["listeningSessionID"] == nil)
        let noArt = TrackMetadata(id: "pid:1", title: "T", artist: "A", album: "B", duration: 1)
        let trackObject = try #require(try JSONSerialization.jsonObject(with: StandByWire.makeEncoder().encode(noArt)) as? [String: Any])
        #expect(trackObject["artworkID"] == nil)
    }

    @Test func extrapolatesWhilePlayingAndClamps() {
        let m = message(elapsed: 10, at: 1000)
        #expect(m.elapsed(at: Date(timeIntervalSince1970: 1005)) == 15)
        #expect(m.elapsed(at: Date(timeIntervalSince1970: 999)) == 10)
        #expect(m.elapsed(at: Date(timeIntervalSince1970: 100_000)) == 473.114)
        #expect(message(state: .paused).elapsed(at: Date(timeIntervalSince1970: 2000)) == 10)
    }

    @Test func revisionOrdering() {
        let current = message(revision: 5)
        #expect(current.isSuperseded(by: message(revision: 6)))
        #expect(current.isSuperseded(by: message(revision: 5)))
        #expect(!current.isSuperseded(by: message(revision: 4)))
    }

    @Test func progressIsNotAVisibleChange() {
        let first = message(elapsed: 10, at: 1000)
        let later = message(revision: 2, elapsed: 14.5, at: 1004)
        #expect(!later.hasVisibleChange(from: first))
    }

    @Test func seekIsAVisibleChange() {
        let first = message(elapsed: 10, at: 1000)
        #expect(message(revision: 2, elapsed: 120, at: 1004).hasVisibleChange(from: first))
        #expect(message(revision: 2, elapsed: 0, at: 1004).hasVisibleChange(from: first))
    }

    @Test func stateTrackAndSessionChangesAreVisible() {
        let first = message()
        #expect(message(revision: 2, state: .paused).hasVisibleChange(from: first))
        var other = Fixture.losingMyEdge
        other.id = "pid:542CEB17C137B3A5"
        #expect(message(revision: 2, track: other).hasVisibleChange(from: first))
        #expect(message(revision: 2, session: UUID()).hasVisibleChange(from: first))
        #expect(message().hasVisibleChange(from: nil))
    }

    @Test func volumeAndOutputsRoundTripAndAreOmittedWhenUnknown() throws {
        let outputs = [AudioOutput(id: "name:Alistair's MacBook Pro", name: "Alistair's MacBook Pro", kind: .computer, isSelected: true),
                       AudioOutput(id: "e4:6e:91:c0:a6:d2", name: "Living Room", kind: .homePod, isSelected: false)]
        var m = message()
        m.volume = 0.65
        m.outputs = outputs
        let data = try StandByWire.makeEncoder().encode(m)
        let decoded = try StandByWire.makeDecoder().decode(PlaybackMessage.self, from: data)
        #expect(decoded.volume == 0.65)
        #expect(decoded.outputs == outputs)
        let object = try #require(try JSONSerialization.jsonObject(with: StandByWire.makeEncoder().encode(message())) as? [String: Any])
        #expect(object["volume"] == nil && object["outputs"] == nil, "a Mac that doesn't report them sends nothing")
        let unknownKind = #"{"id":"x","name":"X","kind":"hologram","isSelected":false,"isAvailable":true}"#
        #expect(try StandByWire.makeDecoder().decode(AudioOutput.self, from: Data(unknownKind.utf8)).kind.rawValue == "hologram")
        #expect(AudioOutput.makeID(networkAddress: " AA:BB ", name: "n") == "aa:bb")
        #expect(AudioOutput.makeID(networkAddress: nil, name: "Study HomePod") == "name:Study HomePod")
    }

    @Test func catalogueIDAndUpNextRoundTripAndAreOmittedWhenUnknown() throws {
        var track = Fixture.losingMyEdge
        track.catalogID = "1102360418"
        var m = message(track: track)
        m.upNext = [QueuedTrack(catalogID: "1102359994", title: "Lady Divine", artist: "Alela Diane", duration: 312.3),
                    QueuedTrack(catalogID: nil, title: "Uploaded demo", artist: "Me", duration: 0)]
        let decoded = try StandByWire.makeDecoder().decode(PlaybackMessage.self, from: StandByWire.makeEncoder().encode(m))
        #expect(decoded.track?.catalogID == "1102360418")
        #expect(decoded.upNext == m.upNext)
        let plain = try #require(try JSONSerialization.jsonObject(with: StandByWire.makeEncoder().encode(message())) as? [String: Any])
        let plainTrack = try #require(plain["track"] as? [String: Any])
        #expect(plain["upNext"] == nil && plainTrack["catalogID"] == nil, "a Mac that can't read them sends nothing")
        // A message from before 12 November decodes with neither.
        let older = #"{"revision":1,"state":"playing","isPlaying":true,"elapsedTime":3,"capturedAt":"2026-11-09T07:00:00.250Z","track":{"id":"pid:1","title":"T","artist":"A","album":"B","duration":1},"canGoNext":true,"canGoPrevious":true}"#
        let old = try StandByWire.makeDecoder().decode(PlaybackMessage.self, from: Data(older.utf8))
        #expect(old.track?.catalogID == nil && old.upNext == nil)
    }

    @Test func upNextAloneIsNotAVisibleChangeButACatalogueIDIs() {
        var first = message()
        first.upNext = [QueuedTrack(catalogID: "1", title: "A", artist: "B", duration: 1)]
        var reordered = message(revision: 2)
        reordered.upNext = [QueuedTrack(catalogID: "2", title: "C", artist: "D", duration: 2)] + (first.upNext ?? [])
        #expect(!reordered.hasVisibleChange(from: first), "a queue edit alone would cost the phone a push")
        var identified = message(revision: 2)
        identified.track?.catalogID = "1102360418"
        #expect(identified.hasVisibleChange(from: first))
    }

    @Test func volumeAndOutputChangesAreVisible() {
        var first = message()
        first.volume = 0.5
        first.outputs = [AudioOutput(id: "a", name: "A", kind: .computer, isSelected: true)]
        var louder = message(revision: 2)
        louder.volume = 0.6
        louder.outputs = first.outputs
        #expect(louder.hasVisibleChange(from: first))
        var moved = message(revision: 2)
        moved.volume = 0.5
        moved.outputs = [AudioOutput(id: "a", name: "A", kind: .computer, isSelected: false)]
        #expect(moved.hasVisibleChange(from: first))
        var same = message(revision: 2, elapsed: 11, at: 1001)
        same.volume = 0.5
        same.outputs = first.outputs
        #expect(!same.hasVisibleChange(from: first))
    }

    @Test func positionIsIgnoredWhenNothingIsLoaded() {
        let first = message(state: .stopped, elapsed: 0, track: nil, session: nil)
        #expect(!message(revision: 2, state: .stopped, elapsed: 99, track: nil, session: nil).hasVisibleChange(from: first))
    }
}

@Suite struct IdentityTests {
    @Test func trackIDPrefersPersistentID() {
        #expect(TrackID.make(persistentID: "542ceb17c137b39e", title: "T", artist: "A", album: "B", duration: 1) == "pid:542CEB17C137B39E")
    }

    @Test func trackIDFallsBackToAStableHash() {
        let a = TrackID.make(persistentID: nil, title: "Losing My Edge", artist: "LCD Soundsystem", album: "LCD Soundsystem", duration: 473.114)
        let b = TrackID.make(persistentID: "  ", title: "Losing My Edge", artist: "LCD Soundsystem", album: "LCD Soundsystem", duration: 473.0)
        #expect(a == b)
        #expect(a.hasPrefix("key:"))
        #expect(a.count == 4 + 32)
        #expect(a != TrackID.make(persistentID: nil, title: "Losing My Edge", artist: "LCD Soundsystem", album: "LCD Soundsystem", duration: 480))
    }

    @Test func fallbackKeyMatchesThePrototype() {
        #expect(TrackID.fallbackKey(title: "T", artist: "A", album: "B", duration: 473.114) == "T|A|B|473")
        #expect(TrackID.fallbackKey(title: "T", artist: "A", album: "B", duration: .infinity) == "T|A|B|0")
    }

    @Test func artworkIDIsLowercaseSHA256() {
        // SHA-256("abc"), FIPS 180-2 test vector.
        #expect(ArtworkID.make(sourceBytes: Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(ArtworkID.isValid(Fixture.artworkID))
        #expect(!ArtworkID.isValid(Fixture.artworkID.uppercased()))
        #expect(!ArtworkID.isValid("a1"))
    }

    @Test func deviceKindIsOpen() throws {
        let json = #"{"id":"x","name":"Hub","kind":"homepod"}"#
        let device = try StandByWire.makeDecoder().decode(DeviceIdentity.self, from: Data(json.utf8))
        #expect(device.kind == DeviceKind(rawValue: "homepod"))
    }
}

@Suite struct CommandTests {
    @Test func expiryUsesIssueTime() {
        let issued = Date(timeIntervalSince1970: 1000)
        let command = RemoteCommand(kind: .play, issuedAt: issued)
        #expect(!command.isExpired(at: issued.addingTimeInterval(9.9)))
        #expect(command.isExpired(at: issued.addingTimeInterval(10.1)))
        #expect(!RemoteCommand(kind: .play).isExpired(at: .distantFuture))
    }

    @Test func valueCommandsCarryTheirValueAndCheckIt() throws {
        let seek = RemoteCommand.seek(to: 120.5, id: Fixture.commandID)
        let data = try StandByWire.makeEncoder().encode(seek)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["kind"] as? String == "seek")
        #expect(object["position"] as? Double == 120.5)
        #expect(object["level"] == nil && object["outputID"] == nil)
        #expect(try StandByWire.makeDecoder().decode(RemoteCommand.self, from: data) == seek)
        #expect(seek.hasRequiredValue)
        #expect(RemoteCommand.setVolume(0.3).hasRequiredValue)
        #expect(RemoteCommand.selectOutput("aa:bb").hasRequiredValue)
        #expect(RemoteCommand(kind: .play).hasRequiredValue)
        #expect(!RemoteCommand(kind: .seek).hasRequiredValue)
        #expect(!RemoteCommand(kind: .setVolume, level: .nan).hasRequiredValue)
        #expect(!RemoteCommand(kind: .selectOutput, outputID: "").hasRequiredValue)
        #expect(CommandKind.seek.requiredValue == "position" && CommandKind.next.requiredValue == nil)
        let json = #"{"id":"5C1F7A9E-2B4D-4C61-8E3F-0A9B8C7D6E5F","kind":"play","position":1}"#
        #expect(try StandByWire.makeDecoder().decode(RemoteCommand.self, from: Data(json.utf8)).position == 1, "a stray value is kept, and ignored by the Mac")
    }

    @Test func temporaryContractCommandStillDecodes() throws {
        let json = #"{"id":"5C1F7A9E-2B4D-4C61-8E3F-0A9B8C7D6E5F","kind":"next"}"#
        let command = try StandByWire.makeDecoder().decode(RemoteCommand.self, from: Data(json.utf8))
        #expect(command == RemoteCommand(id: Fixture.commandID, kind: .next))
    }

    @Test func lowercaseUUIDsDecode() throws {
        let json = #"{"id":"5c1f7a9e-2b4d-4c61-8e3f-0a9b8c7d6e5f","kind":"play"}"#
        #expect(try StandByWire.makeDecoder().decode(RemoteCommand.self, from: Data(json.utf8)).id == Fixture.commandID)
    }

    @Test func ackHelpers() {
        #expect(CommandAck.accepted(Fixture.commandID, revision: 3) == CommandAck(commandID: Fixture.commandID, accepted: true, revision: 3))
        let rejected = CommandAck.rejected(Fixture.commandID, revision: 3, ProtocolError(.commandExpired))
        #expect(!rejected.accepted)
        #expect(rejected.error?.code == .commandExpired)
    }

    @Test func unknownErrorCodesSurvive() throws {
        let json = #"{"code":"quota_exceeded","retryAfter":30}"#
        let error = try StandByWire.makeDecoder().decode(ProtocolError.self, from: Data(json.utf8))
        #expect(error.code.rawValue == "quota_exceeded")
        #expect(error.retryAfter == 30)
    }
}

@Suite struct FrameTests {
    @Test func unknownFrameTypesDecodeAsUnknown() throws {
        #expect(try MacFrame.decode(Data(#"{"type":"volume","level":0.5}"#.utf8)) == .unknown(type: "volume"))
        #expect(try RelayFrame.decode(Data(#"{"type":"ping"}"#.utf8)) == .unknown(type: "ping"))
    }

    @Test func commandWithUnknownKindCanStillBeRejectedByID() throws {
        let json = #"{"type":"command","command":{"id":"5C1F7A9E-2B4D-4C61-8E3F-0A9B8C7D6E5F","kind":"shuffle"}}"#
        let frame = try RelayFrame.decode(Data(json.utf8))
        #expect(frame == .unsupportedCommand(id: Fixture.commandID, kind: "shuffle"))
        #expect(try Fixture.sameJSON(frame.encoded(), Data(json.utf8)))
    }

    @Test func commandWithoutReadableIDFailsToDecode() {
        let json = #"{"type":"command","command":{"kind":"play"}}"#
        #expect(throws: DecodingError.self) { try RelayFrame.decode(Data(json.utf8)) }
    }

    @Test func frameWithoutTypeFailsToDecode() {
        #expect(throws: DecodingError.self) { try MacFrame.decode(Data(#"{"message":{}}"#.utf8)) }
    }
}

@Suite struct ConnectionStatusTests {
    @Test func roundTripsEveryPhase() throws {
        let statuses: [ConnectionStatus] = [
            .disconnected, .connecting, .connected(to: "Studio Mac", since: Date(timeIntervalSince1970: 1)),
            .reconnecting(at: Date(timeIntervalSince1970: 2), after: ProtocolError(.notConnected)),
            .failed(ProtocolError(.pairingRevoked, message: "unpaired")),
        ]
        for status in statuses {
            let data = try StandByWire.makeEncoder().encode(status)
            #expect(try StandByWire.makeDecoder().decode(ConnectionStatus.self, from: data) == status)
        }
        #expect(ConnectionStatus.Phase.allCases.count == 5)
    }
}
