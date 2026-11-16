import Foundation
import Testing
@testable import StandByKit

/// The demo App Review sees: a simulated Mac standing in for a paired one,
/// without replacing the app's model (16 November 2026).
@MainActor
struct DemoModeTests {
    let real = FakeTransport(issuesSessionIDs: true)
    let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!

    private func model(startsInDemo: Bool = false) -> AppModel {
        AppModel(
            transport: DemoCapableTransport(real: real, startsInDemo: startsInDemo),
            sessionController: FakeSessionController(),
            container: SharedContainer(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)),
            defaults: defaults,
            registrar: MockPushTokenRegistrar(container: SharedContainer(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)))
        )
    }

    @Test func theDemoStandsInForAPairedMacAndLeavesNoTrace() async {
        let model = model()
        #expect(model.canTryDemo)
        let task = Task { await model.start() }
        defer { task.cancel() }
        await eventually("subscribed") { await real.subscribeCount == 1 }

        await model.startDemo()
        #expect(model.isDemo)
        #expect(model.pairedMac == DemoMode.mac)
        #expect(DemoMode.isOn(defaults))
        await eventually("the demo's Mac is connected") { model.connection == .connected(macName: "Demo Mac") }
        await eventually("its song arrives") { model.attributes?.track?.id == "mock-1" }

        await model.send(.next)
        await eventually("a skip changes the song") { model.attributes?.track?.id == "mock-2" }
        #expect(await real.sent.isEmpty)

        await model.leaveDemo()
        #expect(!model.isDemo)
        #expect(model.pairedMac == nil)
        #expect(model.attributes == nil)
        #expect(!DemoMode.isOn(defaults))
        // The real transport was never unpaired, and its events reach the model again.
        #expect(await real.unpairCount == 0)
        await real.emit(.connection(.connected(macName: "Studio Mac")))
        await eventually("the real transport is followed again") { model.connection == .connected(macName: "Studio Mac") }
    }

    @Test func aRealPairingIsNeverSetAside() async {
        PairingStore(defaults: defaults).pairedMac = PairedMac(id: "a", name: "Studio Mac")
        let model = model()
        await model.startDemo()
        #expect(!model.isDemo)
        #expect(model.pairedMac?.name == "Studio Mac")
        #expect(!DemoMode.isOn(defaults))
    }

    @Test func theDemoIsRememberedAcrossLaunches() async {
        defaults.set(true, forKey: DemoMode.key)
        PairingStore(defaults: defaults).pairedMac = DemoMode.mac
        let model = model(startsInDemo: true)
        #expect(model.isDemo)
        let task = Task { await model.start() }
        defer { task.cancel() }
        await eventually("the demo's Mac is connected") { model.connection == .connected(macName: "Demo Mac") }
        #expect(await real.connectCount == 0)
    }

    @Test func aStrayFlagWithoutTheDemoMacIsCleared() {
        defaults.set(true, forKey: DemoMode.key)
        #expect(!DemoMode.resumes(defaults))
        #expect(!DemoMode.isOn(defaults))
        defaults.set(true, forKey: DemoMode.key)
        PairingStore(defaults: defaults).pairedMac = DemoMode.mac
        #expect(DemoMode.resumes(defaults))
    }

    @Test func sessionNamingFollowsWhicheverMacIsInUse() async {
        let transport = DemoCapableTransport(real: real, startsInDemo: false)
        #expect(transport.issuesSessionIDs)
        _ = await transport.startDemo()
        #expect(!transport.issuesSessionIDs)
        await transport.endDemo()
        #expect(transport.issuesSessionIDs)
    }

    @Test func theDemoMacsSpeakersCarryItsName() async throws {
        let transport = MockTransport(mac: DemoMode.mac)
        let events = await transport.subscribe()
        await transport.connect()
        for await event in events {
            if case .playback(let message) = event {
                #expect(message.outputs?.first(where: \.isSelected)?.name == "Demo Mac")
                return
            }
        }
    }
}
