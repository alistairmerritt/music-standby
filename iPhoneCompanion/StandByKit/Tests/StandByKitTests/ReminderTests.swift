import Foundation
import Testing
@testable import StandByKit

private struct Permission: NotificationPermission {
    let granted: Bool
    func request() async -> Bool { granted }
}

private actor RecordingRelay: ReminderRelay {
    private(set) var registered: [String] = []
    private(set) var unregistrations = 0
    var failing = false
    func register(alertToken hex: String) async throws {
        if failing { throw TransportError.network("offline") }
        registered.append(hex)
    }
    func unregister() async throws { unregistrations += 1 }
    func fail() { failing = true }
}

@MainActor
private final class ReminderHarness {
    let defaults = UserDefaults(suiteName: "reminders-\(UUID().uuidString)")!
    let relay = RecordingRelay()
    var registrationRequests = 0

    func model(granted: Bool = true) -> ReminderModel {
        ReminderModel(defaults: defaults, permission: Permission(granted: granted), relay: relay) { [unowned self] in
            self.registrationRequests += 1
        }
    }
}

@MainActor
@Suite struct ReminderTests {
    @Test func turningOnAsksPermissionThenSendsTheTokenToTheRelay() async {
        let h = ReminderHarness()
        let model = h.model()
        await model.setEnabled(true)
        #expect(model.isEnabled)
        #expect(h.registrationRequests == 1)
        await model.didRegister(deviceToken: Data([0xAB, 0x01]))
        #expect(await h.relay.registered == ["ab01"])
        #expect(model.problem == nil)
    }

    @Test func refusedPermissionLeavesItOffAndSaysWhy() async {
        let h = ReminderHarness()
        let model = h.model(granted: false)
        await model.setEnabled(true)
        #expect(!model.isEnabled)
        #expect(h.registrationRequests == 0)
        #expect(model.problem?.contains("Settings") == true)
    }

    @Test func turningOffTellsTheRelayAndIgnoresALateToken() async {
        let h = ReminderHarness()
        let model = h.model()
        await model.setEnabled(true)
        await model.setEnabled(false)
        #expect(await h.relay.unregistrations == 1)
        await model.didRegister(deviceToken: Data([0x01]))
        #expect(await h.relay.registered.isEmpty)
    }

    @Test func theChoiceSurvivesARelaunchAndRefreshAsksForTheTokenAgain() async {
        let h = ReminderHarness()
        await h.model().setEnabled(true)
        let relaunched = h.model()
        #expect(relaunched.isEnabled)
        relaunched.refresh()
        #expect(h.registrationRequests == 2)
        let off = ReminderHarness().model()
        off.refresh()
        #expect(!off.isEnabled)
    }

    @Test func aFailedUploadIsShown() async {
        let h = ReminderHarness()
        let model = h.model()
        await model.setEnabled(true)
        await h.relay.fail()
        await model.didRegister(deviceToken: Data([0x01]))
        #expect(model.problem?.hasPrefix("Couldn’t turn on reminders") == true)
    }
}

@Suite struct ReminderRelayClientTests {
    @Test func putsAndDeletesTheAlertToken() async throws {
        let http = FakeHTTP([.noContent, .noContent])
        let relay = RelayReminderRelay { RelayClient(credential: testCredential, http: http) }
        try await relay.register(alertToken: "ab01")
        try await relay.unregister()
        let requests = await http.requests
        #expect(requests[0].httpMethod == "PUT")
        #expect(requests[0].url?.path() == "/v1/tokens/alert")
        let body = try JSONSerialization.jsonObject(with: try #require(requests[0].httpBody)) as? [String: String]
        #expect(body == ["token": "ab01"])
        #expect(requests[1].httpMethod == "DELETE")
        #expect(requests[1].url?.path() == "/v1/tokens/alert")
    }

    @Test func withoutAPairingNothingIsSent() async throws {
        let relay = RelayReminderRelay { nil }
        try await relay.register(alertToken: "ab")
        try await relay.unregister()
    }
}
