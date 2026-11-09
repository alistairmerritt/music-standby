import Foundation
import Testing
@testable import StandByProtocol

// Every file in Examples/ is decoded here and re-encoded, so the JSON in the
// documentation cannot drift from the Swift types.

enum Fixture {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Examples")

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(name + ".json"))
    }

    /// Compares as parsed JSON, so whitespace and key order don't matter.
    static func sameJSON(_ a: Data, _ b: Data) throws -> Bool {
        let x = try JSONSerialization.jsonObject(with: a) as AnyObject
        let y = try JSONSerialization.jsonObject(with: b) as AnyObject
        return x.isEqual(y)
    }

    static func date(_ text: String) -> Date { StandByWire.parseDate(text)! }
    static let commandID = UUID(uuidString: "5C1F7A9E-2B4D-4C61-8E3F-0A9B8C7D6E5F")!
    static let sessionID = UUID(uuidString: "0C7E4A52-3D2B-4F3E-9A61-6B1F2E8D9C10")!
    static let artworkID = "70d7210ced944748a7993e51335d627d93bebede61315de62de3314c2413397d"

    static let losingMyEdge = TrackMetadata(
        id: "pid:542CEB17C137B39E", title: "Losing My Edge", artist: "LCD Soundsystem", album: "LCD Soundsystem",
        duration: 473.114, artworkID: artworkID)
}

@Suite struct ExampleTests {
    @Test func everyExampleIsCovered() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: Fixture.directory.path)
            .filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
        #expect(names == Self.covered.sorted())
    }

    static let covered = [
        "mac-hello", "mac-state-playing", "mac-state-not-running", "mac-state-automation-denied",
        "mac-ack-accepted", "mac-ack-rejected", "mac-artwork", "mac-goodbye",
        "relay-welcome", "relay-command", "relay-artwork-request", "relay-paired", "relay-revoked", "relay-error",
        "http-command-request", "http-command-response", "http-error-response", "legacy-playback-message",
    ]

    @Test(arguments: ["mac-hello", "mac-state-playing", "mac-state-not-running", "mac-state-automation-denied",
                      "mac-ack-accepted", "mac-ack-rejected", "mac-artwork", "mac-goodbye"])
    func macFrameRoundTrips(_ name: String) throws {
        let data = try Fixture.data(name)
        let frame = try MacFrame.decode(data)
        if case .unknown = frame { Issue.record("\(name) decoded as unknown") }
        #expect(try Fixture.sameJSON(frame.encoded(), data))
    }

    @Test(arguments: ["relay-welcome", "relay-command", "relay-artwork-request", "relay-paired", "relay-revoked", "relay-error"])
    func relayFrameRoundTrips(_ name: String) throws {
        let data = try Fixture.data(name)
        let frame = try RelayFrame.decode(data)
        if case .unknown = frame { Issue.record("\(name) decoded as unknown") }
        #expect(try Fixture.sameJSON(frame.encoded(), data))
    }

    @Test func playingStateDecodesToExpectedValues() throws {
        let frame = try MacFrame.decode(Fixture.data("mac-state-playing"))
        let expected = PlaybackMessage(
            revision: 1_794_207_600_001, state: .playing, elapsedTime: 251.5,
            capturedAt: Fixture.date("2026-11-09T07:00:00.250Z"), track: Fixture.losingMyEdge,
            canGoNext: true, canGoPrevious: true, listeningSessionID: Fixture.sessionID)
        #expect(frame == .state(expected))
    }

    @Test func helloDecodesToExpectedValues() throws {
        let frame = try MacFrame.decode(Fixture.data("mac-hello"))
        guard case .hello(let hello) = frame else { Issue.record("not hello"); return }
        #expect(hello.protocolVersion == StandByWire.version)
        #expect(hello.device.kind == .mac)
        #expect(hello.device.name == "Studio Mac")
        #expect(PairedMac(hello.device) == PairedMac(id: "6F9619FF-8B86-D011-B42D-00C04FC964FF", name: "Studio Mac"))
    }

    @Test func rejectedAckCarriesItsError() throws {
        guard case .ack(let ack) = try MacFrame.decode(Fixture.data("mac-ack-rejected")) else { Issue.record("not ack"); return }
        #expect(!ack.accepted)
        #expect(ack.error?.code == .musicNotRunning)
    }

    @Test func commandDecodesWithIssueTime() throws {
        let frame = try RelayFrame.decode(Fixture.data("relay-command"))
        #expect(frame == .command(RemoteCommand(id: Fixture.commandID, kind: .pause, issuedAt: Fixture.date("2026-11-09T07:00:01.125Z"))))
    }

    @Test func httpBodiesRoundTrip() throws {
        let decoder = StandByWire.makeDecoder()
        let encoder = StandByWire.makeEncoder()
        let request = try decoder.decode(CommandRequest.self, from: Fixture.data("http-command-request"))
        #expect(request.command.kind == .next)
        #expect(try Fixture.sameJSON(encoder.encode(request), Fixture.data("http-command-request")))
        let response = try decoder.decode(CommandResponse.self, from: Fixture.data("http-command-response"))
        #expect(response.ack == .accepted(Fixture.commandID, revision: 1_794_207_600_004))
        #expect(try Fixture.sameJSON(encoder.encode(response), Fixture.data("http-command-response")))
        let error = try decoder.decode(ErrorResponse.self, from: Fixture.data("http-error-response"))
        #expect(error.error.code == .macUnreachable)
        #expect(try Fixture.sameJSON(encoder.encode(error), Fixture.data("http-error-response")))
    }
}
