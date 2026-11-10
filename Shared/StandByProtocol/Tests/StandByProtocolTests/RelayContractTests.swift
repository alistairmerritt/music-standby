import Foundation
import Testing
@testable import StandByProtocol

/// The relay API bodies (docs/relay/API-v1.md), checked against Examples/.
@Suite struct RelayContractTests {
    private func roundTrip<T: Codable & Equatable>(_ type: T.Type, _ name: String) throws -> T {
        let data = try Fixture.data(name)
        let value = try StandByWire.makeDecoder().decode(T.self, from: data)
        #expect(try Fixture.sameJSON(StandByWire.makeEncoder().encode(value), data), "\(name) changed in a round trip")
        return value
    }

    @Test func pairingBodiesRoundTrip() throws {
        let create = try roundTrip(PairingCreateRequest.self, "http-pairing-create-request")
        #expect(create.device.kind == .mac)
        let created = try roundTrip(PairingCreateResponse.self, "http-pairing-create-response")
        #expect(created.macToken.hasPrefix("msb1.mac.\(created.pairingID)."))
        let code = try roundTrip(PairingCodeResponse.self, "http-pairing-code-response")
        #expect(code.code.count == 6)
        let claim = try roundTrip(PairingClaimRequest.self, "http-pairing-claim-request")
        #expect(claim.phone.kind == .iPhone)
        let claimed = try roundTrip(PairingClaimResponse.self, "http-pairing-claim-response")
        #expect(claimed.mac.name == "Studio Mac")
        #expect(try roundTrip(PairingClaimStatus.self, "http-pairing-claim-pending").status == .pending)
        let approved = try roundTrip(PairingClaimStatus.self, "http-pairing-claim-approved")
        #expect(approved.status == .approved)
        #expect(approved.phoneToken?.hasPrefix("msb1.phone.\(approved.pairingID!).") == true)
    }

    @Test func pairingFramesRoundTrip() throws {
        let request = try RelayFrame.decode(Fixture.data("relay-pair-request"))
        guard case .pairRequest(let body) = request else { Issue.record("not pair-request"); return }
        #expect(body.phone.name == "Alistair's iPhone")
        #expect(try Fixture.sameJSON(request.encoded(), Fixture.data("relay-pair-request")))

        let decision = try MacFrame.decode(Fixture.data("mac-pair-decision"))
        #expect(decision == .pairDecision(claimID: "c7b2e4f1a0d94b3e8c6f5a2d1e0b9c8a", approved: true))
        #expect(try Fixture.sameJSON(decision.encoded(), Fixture.data("mac-pair-decision")))
    }

    @Test func commandRequestCarriesTheSession() throws {
        let request = try roundTrip(CommandRequest.self, "http-command-request")
        #expect(request.sessionID == "9d0f3c2a-6b1e-4f7d-8a5c-2e4b6d8f0a1c")
        // The PR #1 shape, without a session, still decodes.
        let old = #"{"command":{"id":"5C1F7A9E-2B4D-4C61-8E3F-0A9B8C7D6E5F","kind":"next"}}"#
        #expect(try StandByWire.makeDecoder().decode(CommandRequest.self, from: Data(old.utf8)).sessionID == nil)
    }

    @Test func tokenAndSessionBodiesRoundTrip() throws {
        #expect(try roundTrip(PushToStartTokenRegistration.self, "http-token-start").token.allSatisfy(\.isHexDigit))
        #expect(try roundTrip(SessionPushTokenRegistration.self, "http-token-session").sessionID.count == 36)
        #expect(try roundTrip(SessionEndRequest.self, "http-session-end").sessionID.count == 36)
    }

    @Test func sessionStateMatchesItsOwnAttributes() throws {
        let state = try roundTrip(SessionState.self, "http-session-state")
        let attributes = try #require(state.attributes)
        let playback = try #require(state.playback)
        #expect(attributes.id == state.sessionID)
        #expect(attributes.revision == playback.revision)
        #expect(attributes.isPlaying == playback.isPlaying)
        #expect(attributes.timestamp == playback.capturedAt)
        #expect(attributes.track?.id == playback.track?.id)
        #expect(attributes.track?.artworkURL?.query()?.hasPrefix("sig=") == true)
    }

    /// The push payload's `attributes` decode as NowPlayingAttributes. A track
    /// without artwork has `artworkID: ""` and no URL, as the iOS type needs.
    @Test func apnsPayloadAttributesDecode() throws {
        let object = try #require(try JSONSerialization.jsonObject(with: Fixture.data("apns-update-payload")) as? [String: Any])
        let aps = try #require(object["aps"] as? [String: Any])
        #expect(aps["event"] as? String == "update")
        #expect(aps["timestamp"] is NSNumber)
        let attributes = try StandByWire.makeDecoder().decode(
            NowPlayingAttributes.self, from: JSONSerialization.data(withJSONObject: try #require(aps["attributes"])))
        #expect(attributes.track?.artworkID == "")
        #expect(attributes.track?.artworkURL == nil)
        #expect(!attributes.isPlaying)
    }

    @Test func relayErrorCodesAreStable() {
        #expect(ErrorCode.sessionMismatch.rawValue == "session_mismatch")
        #expect(ErrorCode.noSession.rawValue == "no_session")
        #expect(ErrorCode.pairingCodeInvalid.rawValue == "pairing_code_invalid")
        #expect(ErrorCode.unauthorized.rawValue == "unauthorized")
    }
}
