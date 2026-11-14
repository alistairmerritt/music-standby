import Foundation
import Testing
@testable import StandByKit

private func temporaryContainer() -> SharedContainer {
    SharedContainer(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory))
}

private func attributes(revision: UInt64 = 1, isPlaying: Bool = true, elapsed: TimeInterval = 10, timestamp: Date = Date(timeIntervalSince1970: 1000), trackID: String = "mock-1") -> MacPlaybackAttributes {
    MacPlaybackAttributes(
        id: "mac-mock", macName: "Mock Mac", revision: revision, isPlaying: isPlaying, elapsedTime: elapsed, timestamp: timestamp,
        track: SessionTrack(id: trackID, title: "T", artist: "A", album: "B", duration: 100, artworkID: "mock-art-1"),
        canGoNext: true, canGoPrevious: true
    )
}

@Suite struct PairingTests {
    @Test func acceptsExactlySixDigits() {
        #expect(PairingCode("123456")?.value == "123456")
        #expect(PairingCode("12345") == nil)
        #expect(PairingCode("1234567") == nil)
        #expect(PairingCode("12a456") == nil)
        #expect(PairingCode("١٢٣٤٥٦") == nil)
    }

    @Test func sanitisesPastedText() {
        #expect(PairingCode.sanitise(" 12-34 56789") == "123456")
        #expect(PairingCode.sanitise("abc") == "")
    }

    @Test func persistsAndClearsPairedMac() throws {
        let suite = "test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PairingStore(defaults: defaults)
        #expect(store.pairedMac == nil)
        store.pairedMac = PairedMac(id: "a", name: "Studio Mac")
        #expect(store.pairedMac?.name == "Studio Mac")
        store.pairedMac = nil
        #expect(store.pairedMac == nil)
    }
}

@Suite struct AttributesTests {
    @Test func extrapolatesWhilePlayingAndClamps() {
        let a = attributes()
        #expect(a.elapsed(at: Date(timeIntervalSince1970: 1005)) == 15)
        #expect(a.elapsed(at: Date(timeIntervalSince1970: 5000)) == 100)
        #expect(a.elapsed(at: Date(timeIntervalSince1970: 900)) == 10)
    }

    @Test func holdsPositionWhilePaused() {
        let a = attributes(isPlaying: false)
        #expect(a.elapsed(at: Date(timeIntervalSince1970: 1500)) == 10)
    }

    @Test func revisionGate() {
        let current = attributes(revision: 5)
        #expect(current.shouldBeReplaced(by: attributes(revision: 6)))
        #expect(current.shouldBeReplaced(by: attributes(revision: 5)))
        #expect(!current.shouldBeReplaced(by: attributes(revision: 4, timestamp: Date(timeIntervalSince1970: 1002))))
    }

    @Test func restartedMacIsAcceptedDespiteLowerRevision() {
        let current = attributes(revision: 5000)
        #expect(current.shouldBeReplaced(by: attributes(revision: 1, timestamp: Date(timeIntervalSince1970: 1100))))
    }

    /// Same shape as Apple's documented push payload: ISO-8601 date strings.
    @Test func decodesPushPayloadAttributes() throws {
        let json = """
        {"id":"mac-mock","macName":"Studio Mac","revision":42,"isPlaying":true,"elapsedTime":12.5,
         "timestamp":"2026-11-08T08:00:00Z","canGoNext":true,"canGoPrevious":false,
         "track":{"id":"t","title":"Song","artist":"Artist","album":"Album","duration":200,
                  "artworkID":"a1","artworkURL":"https://example.com/a1.jpg"}}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(MacPlaybackAttributes.self, from: Data(json.utf8))
        #expect(decoded.revision == 42)
        #expect(decoded.track?.artworkURL?.absoluteString == "https://example.com/a1.jpg")
        #expect(decoded.canGoPrevious == false)
    }

    /// What the relay really pushes: the Mac's time with milliseconds. On iOS
    /// 27.2 every such push crashed the extension until the attributes read
    /// their own dates, so this must decode whatever the system's decoder.
    static let relayPushAttributes = """
    {"canGoNext":true,"canGoPrevious":true,"elapsedTime":14,"id":"bc68e82f-4add-4ef8-bd21-37d326bcbb4c",
     "isPlaying":true,"macName":"Alistair's MacBook Pro","revision":1794351143767,
     "timestamp":"2026-11-11T09:53:26.250Z",
     "track":{"album":"Six Songs - EP","artist":"Tom Misch","artworkID":"a1b2","artworkURL":"https://relay.example/v1/artwork/p/s",
              "duration":195.2,"id":"pid:542CEB17C137B39E","title":"Insecure"}}
    """

    @Test(arguments: ["default", "iso8601", "wire"])
    func decodesTheRelaysPushWithAnyJSONDateStrategy(_ strategy: String) throws {
        let decoder: JSONDecoder
        switch strategy {
        case "iso8601": decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        case "wire": decoder = StandByWire.makeDecoder()
        default: decoder = JSONDecoder()
        }
        let decoded = try decoder.decode(MacPlaybackAttributes.self, from: Data(Self.relayPushAttributes.utf8))
        #expect(decoded.timestamp == StandByWire.parseDate("2026-11-11T09:53:26.250Z"))
        #expect(decoded.revision == 1794351143767)
        #expect(decoded.track?.title == "Insecure")
        #expect(decoded.track?.artworkURL?.absoluteString == "https://relay.example/v1/artwork/p/s")
    }

    /// The push arrives as JSON but may reach the extension as a dictionary.
    /// A property-list decoder reads URL and Date differently from JSONDecoder.
    @Test func decodesTheRelaysPushAsAPropertyList() throws {
        let object = try JSONSerialization.jsonObject(with: Data(Self.relayPushAttributes.utf8))
        let plist = try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
        let decoded = try PropertyListDecoder().decode(MacPlaybackAttributes.self, from: plist)
        #expect(decoded.timestamp == StandByWire.parseDate("2026-11-11T09:53:26.250Z"))
        #expect(decoded.track?.artworkURL?.absoluteString == "https://relay.example/v1/artwork/p/s")
    }

    @Test func roundTripsThroughJSONAndPropertyLists() throws {
        var a = attributes(timestamp: Date(timeIntervalSince1970: 1_794_351_206.25))
        a.track?.artworkURL = URL(string: "https://relay.example/v1/artwork/p/s")
        #expect(try JSONDecoder().decode(MacPlaybackAttributes.self, from: JSONEncoder().encode(a)) == a)
        #expect(try PropertyListDecoder().decode(MacPlaybackAttributes.self, from: PropertyListEncoder().encode(a)) == a)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(a)) as? [String: Any]
        #expect(json?["timestamp"] as? String == "2026-11-10T22:53:26.250Z")
    }

    /// A DecodingError carries CodingKey values that NSXPC can't encode; the
    /// failure the system sees must carry only strings.
    @Test func aDecodingFailureCanCrossXPC() throws {
        let broken = Self.relayPushAttributes.replacingOccurrences(of: "2026-11-11T09:53:26.250Z", with: "yesterday")
        do {
            _ = try JSONDecoder().decode(MacPlaybackAttributes.self, from: Data(broken.utf8))
            Issue.record("decoded a broken timestamp")
        } catch let failure as AttributesDecodingFailure {
            #expect(failure.description == "timestamp: Expected an ISO-8601 date, got yesterday")
            let userInfo = (failure as NSError).userInfo
            #expect(userInfo.values.allSatisfy { $0 is String })
        }
        let missing = Self.relayPushAttributes.replacingOccurrences(of: "\"macName\":\"Alistair's MacBook Pro\",", with: "")
        #expect(throws: AttributesDecodingFailure.self) { try JSONDecoder().decode(MacPlaybackAttributes.self, from: Data(missing.utf8)) }
    }

    @Test func staysWellInsideAPNsPayloadLimit() throws {
        let long = String(repeating: "x", count: 200)
        var a = attributes()
        a.track = SessionTrack(id: long, title: long, artist: long, album: long, duration: 100, artworkID: long, artworkURL: URL(string: "https://example.com/\(long)"))
        #expect(try JSONEncoder().encode(a).count < 4096)
    }

    @Test func mapsTemporaryMessage() {
        let message = PlaybackMessage(revision: 7, isPlaying: false, elapsedTime: 3, capturedAt: Date(timeIntervalSince1970: 1), track: MockLibrary.standard.tracks[1], canGoNext: true, canGoPrevious: false)
        let mapped = MacPlaybackAttributes(mac: PairedMac(id: "x", name: "Mac"), message: message)
        #expect(mapped.id == "mac-x")
        #expect(mapped.track?.title == "Second Glance")
        #expect(mapped.canGoPrevious == false)
    }
}

@Suite struct OptimisticCommandTests {
    let library = MockLibrary.standard
    let date = Date(timeIntervalSince1970: 1010)

    @Test func nextAdvancesAndResetsPositionWithoutBumpingRevision() {
        let result = library.applying(.next, to: attributes(revision: 9), at: date)
        #expect(result.track?.id == "mock-2")
        #expect(result.elapsedTime == 0)
        #expect(result.timestamp == date)
        #expect(result.revision == 9)
    }

    @Test func previousWrapsToLastTrack() {
        #expect(library.applying(.previous, to: attributes(), at: date).track?.id == "mock-3")
    }

    @Test func pauseCapturesExtrapolatedPosition() {
        let result = library.applying(.pause, to: attributes(), at: date)
        #expect(!result.isPlaying)
        #expect(result.elapsedTime == 20)
    }

    @Test func unknownTrackLeavesSkipUntouched() {
        let original = attributes(trackID: "real-apple-music-id")
        #expect(library.applying(.next, to: original, at: date) == original)
    }
}

@Suite struct MockTransportTests {
    private func playbackEvents(_ stream: AsyncStream<TransportEvent>, count: Int) async -> [PlaybackMessage] {
        var messages: [PlaybackMessage] = []
        for await event in stream {
            if case .playback(let message) = event { messages.append(message) }
            if messages.count == count { break }
        }
        return messages
    }

    @Test func connectEmitsFirstTrack() async {
        let transport = MockTransport()
        let stream = await transport.subscribe()
        await transport.connect()
        let messages = await playbackEvents(stream, count: 1)
        #expect(messages[0].track?.id == "mock-1")
        #expect(messages[0].revision == 1)
    }

    @Test func nextCommandIsAcknowledgedAndAdvances() async throws {
        let transport = MockTransport()
        let stream = await transport.subscribe()
        await transport.connect()
        let command = RemoteCommand(kind: .next)
        let ack = try await transport.send(command)
        #expect(ack.commandID == command.id)
        #expect(ack.accepted)
        #expect(ack.revision == 2)
        let messages = await playbackEvents(stream, count: 2)
        #expect(messages[1].track?.id == "mock-2")
        #expect(messages[1].revision > messages[0].revision)
    }

    @Test func pausePlayKeepsPosition() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 0))
        let transport = MockTransport(now: { clock.now })
        let stream = await transport.subscribe()
        await transport.connect()
        clock.advance(30)
        _ = try await transport.send(RemoteCommand(kind: .pause))
        clock.advance(100)
        _ = try await transport.send(RemoteCommand(kind: .play))
        let messages = await playbackEvents(stream, count: 3)
        #expect(messages[1].elapsedTime == 30)
        #expect(!messages[1].isPlaying)
        #expect(messages[2].elapsedTime == 30)
        #expect(messages[2].isPlaying)
    }

    @Test func commandsFailWhenDisconnected() async {
        let transport = MockTransport()
        await #expect(throws: TransportError.notConnected) {
            _ = try await transport.send(RemoteCommand(kind: .next))
        }
    }

    @Test func pairingRejectsReservedCode() async throws {
        let transport = MockTransport()
        let good = try #require(PairingCode("123456"))
        let bad = try #require(PairingCode(MockTransport.rejectedCode))
        #expect(try await transport.pair(code: good) { _ in }.name == "Mock Mac")
        await #expect(throws: TransportError.pairingRejected) {
            _ = try await transport.pair(code: bad) { _ in }
        }
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ date: Date) { current = date }
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

@Suite struct SharedStateTests {
    @Test func commandLogKeepsOrderAndCaps() throws {
        let log = CommandLog(container: temporaryContainer(), limit: 2)
        for kind in [CommandKind.play, .pause, .next] {
            try log.append(CommandRecord(kind: kind, sessionID: "s", receivedAt: Date()))
        }
        #expect(log.all().map(\.kind) == [.pause, .next])
    }

    @Test func writesSurviveTheContainerBeingCleared() throws {
        let container = temporaryContainer()
        try FileManager.default.removeItem(at: container.directory)
        let log = CommandLog(container: container)
        try log.append(CommandRecord(kind: .next, sessionID: "s", receivedAt: Date()))
        #expect(log.all().count == 1)
    }

    @Test func artworkResolutionPrefersCacheThenGenerates() async throws {
        let store = ArtworkStore(container: temporaryContainer())
        let generated = try await store.resolve(id: "mock-art-2", remoteURL: nil)
        #expect(MockArtwork.decode(generated) != nil)
        try store.save(Data([1, 2, 3]), id: "real/art id")
        #expect(try await store.resolve(id: "real/art id", remoteURL: nil) == Data([1, 2, 3]))
        await #expect(throws: TransportError.artworkUnavailable) {
            _ = try await store.resolve(id: "missing", remoteURL: nil)
        }
    }

    @Test func mockArtworkIsAValidImage() throws {
        let data = try #require(MockArtwork.png(id: "mock-art-1", pixelSize: 64))
        let image = try #require(MockArtwork.decode(data))
        #expect(image.width == 64)
    }

    @Test func tokensEncodeAsLowercaseHexAndPersist() async throws {
        #expect(Data([0x0a, 0xff]).hexString == "0aff")
        let registrar = MockPushTokenRegistrar(container: temporaryContainer())
        try await registrar.registerStartToken("aa")
        try await registrar.registerUpdateToken("bb", forSessionID: "s")
        #expect(registrar.current() == PushTokens(pushToStart: "aa", sessions: ["s": "bb"]))
    }

    @Test func crossProcessSignalIsDelivered() async {
        let name = "test.standby.\(UUID().uuidString)"
        await confirmation("signal received") { received in
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                let box = SignalBox()
                box.signal = CrossProcessSignal(name: name) {
                    received()
                    box.finish(done)
                }
                CrossProcessSignal.post(name)
            }
        }
    }
}

private final class SignalBox: @unchecked Sendable {
    var signal: CrossProcessSignal?
    private let lock = NSLock()
    private var finished = false
    func finish(_ continuation: CheckedContinuation<Void, Never>) {
        lock.withLock {
            guard !finished else { return }
            finished = true
            continuation.resume()
        }
    }
}
