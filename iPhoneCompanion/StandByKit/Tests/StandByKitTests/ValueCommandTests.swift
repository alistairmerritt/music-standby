import Foundation
import Testing
@testable import StandByKit

/// Seek, volume and output selection on the phone: what a drag or a pick
/// sends, and what the development mock does with it. Added 11 November 2026.
@Suite struct ValueCommandTests {
    private let mac = PairedMac(id: "mac-1", name: "Studio Mac")

    private func attributes(volume: Double? = 0.5) -> MacPlaybackAttributes {
        MacPlaybackAttributes(id: "s1", macName: "Studio Mac", revision: 5, isPlaying: true, elapsedTime: 10,
                              timestamp: Date(timeIntervalSince1970: 1000),
                              track: SessionTrack(id: "mock-1", title: "T", artist: "A", album: "B", duration: 200, artworkID: nil),
                              canGoNext: true, canGoPrevious: true, volume: volume)
    }

    @Test func aDragSendsTheCommandWithItsValueUnderTheSessionOnScreen() async throws {
        let sender = RecordingSender()
        let handler = RelayCommandHandler(sender: sender)
        _ = try await handler.perform(.seek(to: 120.5, issuedAt: Date(timeIntervalSince1970: 1)), on: attributes())
        _ = try await handler.perform(.setVolume(0.25), on: attributes())
        _ = try await handler.perform(.next, on: attributes(), at: Date(timeIntervalSince1970: 2))
        let sent = await sender.sent
        #expect(sent.map(\.command.kind) == [.seek, .setVolume, .next])
        #expect(sent[0].command.position == 120.5 && sent[0].command.issuedAt == Date(timeIntervalSince1970: 1))
        #expect(sent[1].command.level == 0.25)
        #expect(sent[2].command.issuedAt == Date(timeIntervalSince1970: 2), "the plain form still stamps the tap's time")
        #expect(sent.allSatisfy { $0.sessionID == "s1" })
    }

    @Test func volumeTravelsInTheAttributesAndIsOptional() throws {
        let encoder = StandByWire.makeEncoder(), decoder = StandByWire.makeDecoder()
        let with = try decoder.decode(MacPlaybackAttributes.self, from: encoder.encode(attributes(volume: 0.3)))
        #expect(with.volume == 0.3)
        let withoutData = try encoder.encode(attributes(volume: nil))
        let object = try #require(try JSONSerialization.jsonObject(with: withoutData) as? [String: Any])
        #expect(object["volume"] == nil)
        #expect(try decoder.decode(MacPlaybackAttributes.self, from: withoutData).volume == nil)
        var message = PlaybackMessage(revision: 9, state: .playing, elapsedTime: 1, capturedAt: Date(), track: nil, canGoNext: false, canGoPrevious: false)
        message.volume = 0.8
        #expect(MacPlaybackAttributes(mac: mac, message: message).volume == 0.8)
        let relay = NowPlayingAttributes(id: "s1", macName: "M", revision: 1, isPlaying: true, elapsedTime: 0, timestamp: Date(),
                                         track: nil, canGoNext: true, canGoPrevious: true, volume: 0.6)
        #expect(MacPlaybackAttributes(relay).volume == 0.6)
    }

    @Test func theMockGuessesSeekAndVolumeAndLeavesOutputsToTheTransport() {
        let library = MockLibrary.standard
        let date = Date(timeIntervalSince1970: 2000)
        let sought = library.applying(.seek(to: 150), to: attributes(), at: date)
        #expect(sought.elapsedTime == 150 && sought.timestamp == date)
        #expect(library.applying(.seek(to: 999), to: attributes(), at: date).elapsedTime == 200, "clamped to the track")
        #expect(library.applying(.seek(to: -5), to: attributes(), at: date).elapsedTime == 0)
        #expect(library.applying(.setVolume(0.9), to: attributes(), at: date).volume == 0.9)
        #expect(library.applying(.setVolume(4), to: attributes(), at: date).volume == 1)
        #expect(library.applying(RemoteCommand(kind: .seek), to: attributes(), at: date) == attributes(), "no value, no change")
        #expect(library.applying(.selectOutput("x"), to: attributes(), at: date) == attributes())
    }

    @Test func theMockMacSwitchesOutputsAndReportsVolume() async throws {
        let transport = MockTransport()
        let events = await transport.subscribe()
        await transport.connect()
        let first = try #require(await nextPlayback(events))
        #expect(first.volume == 0.5)
        let outputs = try #require(first.outputs)
        #expect(outputs.filter(\.isSelected).map(\.name) == ["Mock Mac"])
        let homePod = try #require(outputs.first { $0.kind == .homePod })

        let ack = try await transport.send(.setVolume(0.2))
        #expect(ack.accepted)
        #expect(try #require(await nextPlayback(events)).volume == 0.2)

        #expect(try await transport.send(.selectOutput(homePod.id)).accepted)
        let moved = try #require(await nextPlayback(events))
        #expect(moved.outputs?.filter(\.isSelected).map(\.name) == ["Kitchen HomePod"])

        let refused = try await transport.send(.selectOutput("nope"))
        #expect(!refused.accepted && refused.error?.code == .invalidRequest)
        let noValue = try await transport.send(RemoteCommand(kind: .seek))
        #expect(!noValue.accepted)
    }

    private func nextPlayback(_ events: AsyncStream<TransportEvent>) async -> PlaybackMessage? {
        for await event in events {
            if case .playback(let message) = event { return message }
        }
        return nil
    }
}

private actor RecordingSender: CommandSender {
    private(set) var sent: [(command: RemoteCommand, sessionID: String)] = []
    func send(_ command: RemoteCommand, sessionID: String) async throws -> CommandAck {
        sent.append((command, sessionID))
        return .accepted(command.id, revision: 10)
    }
}
