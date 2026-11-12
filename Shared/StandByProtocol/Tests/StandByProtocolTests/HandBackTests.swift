import Foundation
import Testing
@testable import StandByProtocol

/// Continue from iPhone (HandBack.swift), checked against Examples/.
@Suite struct HandBackTests {
    private let requestID = UUID(uuidString: "3E7A1C5B-9D2F-4A68-B0C4-6E8F1A3B5D7C")!

    private func roundTrip<T: Codable & Equatable>(_ type: T.Type, _ name: String) throws -> T {
        let data = try Fixture.data(name)
        let value = try StandByWire.makeDecoder().decode(T.self, from: data)
        #expect(try Fixture.sameJSON(StandByWire.makeEncoder().encode(value), data), "\(name) changed in a round trip")
        return value
    }

    @Test func framesRoundTrip() throws {
        let request = try MacFrame.decode(Fixture.data("mac-hand-back-request"))
        #expect(request == .handBackRequest(id: requestID))
        #expect(try Fixture.sameJSON(request.encoded(), Fixture.data("mac-hand-back-request")))

        let status = try RelayFrame.decode(Fixture.data("relay-hand-back-status"))
        #expect(status == .handBackStatus(id: requestID, status: .working))
        #expect(try Fixture.sameJSON(status.encoded(), Fixture.data("relay-hand-back-status")))
    }

    @Test func phoneBodiesRoundTrip() throws {
        #expect(try roundTrip(HandBackStatusReport.self, "http-hand-back-status") == HandBackStatusReport(requestID: requestID, status: .done))
        #expect(try roundTrip(DeviceTokenRegistration.self, "http-token-device").token.allSatisfy(\.isHexDigit))
    }

    @Test func bothPushesCarryTheRequestForTheApp() throws {
        for name in ["apns-hand-back-background", "apns-hand-back-alert"] {
            let object = try #require(try JSONSerialization.jsonObject(with: Fixture.data(name)) as? [String: Any])
            let body = try JSONSerialization.data(withJSONObject: try #require(object[HandBackRequest.payloadKey]))
            let request = try StandByWire.makeDecoder().decode(HandBackRequest.self, from: body)
            #expect(request.requestID == requestID)
            #expect(request.expiresAt == Fixture.date("2026-11-12T10:02:00.000Z"))
        }
        let alert = try #require(try JSONSerialization.jsonObject(with: Fixture.data("apns-hand-back-alert")) as? [String: Any])
        #expect((alert["aps"] as? [String: Any])?["thread-id"] as? String == HandBackRequest.threadID)
    }

    @Test func unknownStatusesSurviveAndOnlyAnswersAreFinal() throws {
        let frame = #"{"type":"hand-back-status","requestID":"3E7A1C5B-9D2F-4A68-B0C4-6E8F1A3B5D7C","status":"teleported"}"#
        #expect(try RelayFrame.decode(Data(frame.utf8)) == .handBackStatus(id: requestID, status: "teleported"))
        let answers: [HandBackStatus] = [.done, .nothingPlaying, .notInQueue, .failed, .unreachable]
        let interim: [HandBackStatus] = [.asked, .notified, .working, "teleported"]
        let allAnswersFinal = answers.allSatisfy(\.isFinal), anyInterimFinal = interim.contains(where: \.isFinal)
        #expect(allAnswersFinal)
        #expect(!anyInterimFinal)
    }

    @Test func theContinuePauseSaysWhyAndOlderCommandsStillDecode() throws {
        let frame = try RelayFrame.decode(Fixture.data("relay-command-continue-on-phone"))
        guard case .command(let command) = frame else { Issue.record("not a command"); return }
        #expect(command.kind == .pause && command.reason == .continueOnPhone)
        #expect(try Fixture.sameJSON(frame.encoded(), Fixture.data("relay-command-continue-on-phone")))

        guard case .command(let plain) = try RelayFrame.decode(Fixture.data("relay-command")) else { Issue.record("not a command"); return }
        #expect(plain.reason == nil)
        let encoded = try #require(String(data: try StandByWire.makeEncoder().encode(plain), encoding: .utf8))
        #expect(!encoded.contains("reason"), "a command without a reason sends none")
    }
}
