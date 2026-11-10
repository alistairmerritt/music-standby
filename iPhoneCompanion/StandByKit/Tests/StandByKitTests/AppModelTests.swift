import Foundation
import Testing
@testable import StandByKit

// MARK: - Doubles

actor FakeTransport: PlaybackTransport {
    private var hub = TransportEventHub()
    nonisolated let issuesSessionIDs: Bool
    init(issuesSessionIDs: Bool = false) { self.issuesSessionIDs = issuesSessionIDs }
    private(set) var subscribeCount = 0
    private(set) var connectCount = 0
    private(set) var reconnectCount = 0
    private(set) var unpairCount = 0
    private(set) var sent: [RemoteCommand] = []

    func subscribe() -> AsyncStream<TransportEvent> {
        subscribeCount += 1
        return hub.subscribe()
    }

    func connect() { connectCount += 1 }
    func reconnect() {
        reconnectCount += 1
        hub.send(.connection(.connecting))
        hub.send(.connection(.connected(macName: "Studio Mac")))
    }
    func disconnect() { hub.send(.connection(.disconnected)) }
    func pair(code: PairingCode, progress: @escaping @Sendable (PairingProgress) async -> Void) async -> PairedMac {
        let mac = PairedMac(id: "a", name: "Studio Mac")
        await progress(.waitingForApproval(mac))
        return mac
    }
    func unpair() {
        unpairCount += 1
        hub.send(.connection(.disconnected))
        hub.reset()
    }
    func send(_ command: RemoteCommand) -> CommandAck {
        sent.append(command)
        return .accepted(command.id, revision: 1)
    }
    func artwork(id: String) throws -> Data { throw TransportError.artworkUnavailable }

    func emit(_ event: TransportEvent) { hub.send(event) }
}

@MainActor
final class FakeSessionController: RemoteSessionControlling {
    var isActive = false
    var isSystemPrimary = false
    var sessionID: String?
    var lastError: String?
    var lastPrimaryError: String?

    var failActivation = false
    private(set) var activations: [MacPlaybackAttributes] = []
    private(set) var published: [MacPlaybackAttributes] = []
    private(set) var deactivations = 0
    private(set) var primaryRequests = 0

    func activate(with attributes: MacPlaybackAttributes) async {
        activations.append(attributes)
        if failActivation {
            lastError = "activation failed"
            return
        }
        isActive = true
        sessionID = attributes.id
        lastError = nil
        primaryRequests += 1
    }

    func publish(_ attributes: MacPlaybackAttributes) async {
        guard isActive else { return }
        published.append(attributes)
    }

    func deactivate() async {
        deactivations += 1
        isActive = false
        sessionID = nil
    }

    func requestPrimary() async { primaryRequests += 1 }
    func observePushToStartTokens(registrar: any PushTokenRegistrar) async {}
}

/// Holds each `sleep` until the test releases it.
final class ManualSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Error>] = []

    var pending: Int { lock.withLock { waiters.count } }

    func sleep(_ seconds: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.withLock { waiters.append(continuation) }
        }
    }

    func releaseAll() {
        let released = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            defer { waiters = [] }
            return waiters
        }
        released.forEach { $0.resume() }
    }
}

final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ date: Date = Date(timeIntervalSince1970: 1_000_000)) { current = date }
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

/// Waits for asynchronous delivery without a fixed delay.
@MainActor
func eventually(_ what: Comment, _ condition: @MainActor () async -> Bool) async {
    for _ in 0..<2000 {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("Timed out: \(what)")
}

func track(_ id: String = "t1", artworkID: String? = nil) -> TrackMetadata {
    TrackMetadata(id: id, title: "Song", artist: "Artist", album: "Album", duration: 200, artworkID: artworkID)
}

func message(revision: UInt64 = 1, state: PlaybackState = .playing, track trackValue: TrackMetadata? = track()) -> PlaybackMessage {
    PlaybackMessage(revision: revision, state: state, elapsedTime: 0, capturedAt: Date(timeIntervalSince1970: 1_000_000), track: trackValue, canGoNext: true, canGoPrevious: true)
}

// MARK: - Harness

@MainActor
struct Harness {
    let transport: FakeTransport
    let controller = FakeSessionController()
    let sleeper = ManualSleeper()
    let clock = MutableClock()
    let registrar: MockPushTokenRegistrar
    let model: AppModel
    let defaults: UserDefaults

    init(paired: Bool = true, nowPlayingEnabled: Bool = true, relayNamesSessions: Bool = false) {
        let transport = FakeTransport(issuesSessionIDs: relayNamesSessions)
        self.transport = transport
        let suite = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        self.defaults = defaults
        defaults.set(nowPlayingEnabled, forKey: "nowPlayingEnabled")
        if paired { PairingStore(defaults: defaults).pairedMac = PairedMac(id: "a", name: "Studio Mac") }
        let container = SharedContainer(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory))
        registrar = MockPushTokenRegistrar(container: container)
        let (clock, sleeper) = (self.clock, self.sleeper)
        model = AppModel(
            transport: transport,
            sessionController: controller,
            container: container,
            defaults: defaults,
            registrar: registrar,
            policy: SessionLifecyclePolicy(reconnectGrace: 60),
            now: { clock.now },
            sleep: { try await sleeper.sleep($0) }
        )
    }

    /// Runs the event loop and waits until the transport has been subscribed.
    func run() async -> Task<Void, Never> {
        let before = await transport.subscribeCount
        let task = Task { await model.start() }
        await eventually("subscribed") { await transport.subscribeCount > before }
        return task
    }

    func connected(_ emit: Bool = true) async {
        await transport.emit(.connection(.connected(macName: "Studio Mac")))
        await eventually("connected") { model.connection == .connected(macName: "Studio Mac") }
    }

    func play(revision: UInt64 = 1) async {
        await transport.emit(.playback(message(revision: revision)))
        await eventually("session active") { controller.isActive }
    }
}

// MARK: - Session lifecycle (audit B3)

@MainActor
@Suite struct SessionLifecycleTests {
    @Test func policyEndsOnlyOnConfirmedStates() {
        let policy = SessionLifecyclePolicy()
        #expect(!policy.endsSession(.playing))
        #expect(!policy.endsSession(.paused))
        #expect(!policy.endsSession(.error))
        #expect(policy.endsSession(.stopped))
        #expect(policy.endsSession(.notRunning))
        #expect(policy.endsSession(.automationDenied))
    }

    @Test func policySeparatesTemporaryFromDeliberateDisconnection() {
        let policy = SessionLifecyclePolicy()
        let up = ConnectionState.connected(macName: "M")
        #expect(policy.decision(from: up, to: .reconnecting) == .startGrace)
        #expect(policy.decision(from: .reconnecting, to: .failed("x")) == .keep)
        #expect(policy.decision(from: .reconnecting, to: up) == .cancelGrace)
        #expect(policy.decision(from: .reconnecting, to: .connecting) == .keep)
        #expect(policy.decision(from: up, to: .disconnected) == .end(.macDisconnected))
        #expect(policy.decision(from: .disconnected, to: .disconnected) == .keep)
    }

    @Test func pauseKeepsTheSession() async {
        let h = Harness()
        let task = await h.run()
        defer { task.cancel() }
        await h.connected()
        await h.play()
        await h.transport.emit(.playback(message(revision: 2, state: .paused)))
        await eventually("published") { h.controller.published.last?.isPlaying == false }
        #expect(h.controller.isActive)
        #expect(h.controller.deactivations == 0)
    }

    @Test func oneOffReadErrorKeepsTheSession() async {
        let h = Harness()
        let task = await h.run()
        defer { task.cancel() }
        await h.connected()
        await h.play()
        await h.transport.emit(.playback(message(revision: 2, state: .error)))
        await eventually("published") { h.controller.published.count == 1 }
        #expect(h.controller.deactivations == 0)
    }

    @Test(arguments: [PlaybackState.stopped, .notRunning, .automationDenied])
    func confirmedTerminationEndsTheSessionAndItsToken(state: PlaybackState) async throws {
        let h = Harness()
        let task = await h.run()
        defer { task.cancel() }
        await h.connected()
        await h.play()
        let id = try #require(h.controller.sessionID)
        try await h.registrar.registerUpdateToken("aa", forSessionID: id)
        await h.transport.emit(.playback(message(revision: 2, state: state, track: nil)))
        await eventually("ended") { !h.controller.isActive }
        #expect(h.controller.deactivations == 1)
        #expect(h.registrar.current().sessions[id] == nil)
    }

    @Test func playbackAfterAStopStartsANewSession() async {
        let h = Harness()
        let task = await h.run()
        defer { task.cancel() }
        await h.connected()
        await h.play(revision: 1)
        await h.transport.emit(.playback(message(revision: 2, state: .stopped, track: nil)))
        await eventually("ended") { !h.controller.isActive }
        await h.play(revision: 3)
        #expect(h.controller.activations.count == 2)
    }

    @Test func briefInterruptionKeepsTheSession() async {
        let h = Harness()
        let task = await h.run()
        defer { task.cancel() }
        await h.connected()
        await h.play()
        await h.transport.emit(.connection(.reconnecting))
        await eventually("grace running") { h.sleeper.pending == 1 }
        #expect(h.controller.isActive)
        await h.connected()
        h.sleeper.releaseAll()
        // Give a wrongly surviving timer the chance to fire.
        await Task.yield()
        await h.transport.emit(.playback(message(revision: 2)))
        await eventually("still publishing") { h.controller.published.count == 1 }
        #expect(h.controller.deactivations == 0)
    }

    @Test func interruptionPastTheGracePeriodEndsTheSession() async {
        let h = Harness()
        let task = await h.run()
        defer { task.cancel() }
        await h.connected()
        await h.play()
        await h.transport.emit(.connection(.reconnecting))
        await eventually("grace running") { h.sleeper.pending == 1 }
        h.sleeper.releaseAll()
        await eventually("ended") { !h.controller.isActive }
        #expect(h.controller.deactivations == 1)
    }

    @Test func graceThatExpiredWhileSuspendedEndsOnForeground() async {
        let h = Harness()
        let task = await h.run()
        defer { task.cancel() }
        await h.connected()
        await h.play()
        await h.transport.emit(.connection(.reconnecting))
        await eventually("grace running") { h.sleeper.pending == 1 }
        h.clock.advance(61)
        await h.model.sceneDidBecomeActive()
        #expect(!h.controller.isActive)
        #expect(h.controller.activations.count == 1, "must not republish a session it just ended")
    }

    @Test func deliberateDisconnectionEndsTheSession() async {
        let h = Harness()
        let task = await h.run()
        defer { task.cancel() }
        await h.connected()
        await h.play()
        await h.transport.disconnect()
        await eventually("ended") { !h.controller.isActive }
    }

    @Test func reconnectButtonKeepsTheSession() async {
        let h = Harness()
        let task = await h.run()
        defer { task.cancel() }
        await h.connected()
        await h.play()
        await h.model.reconnect()
        await eventually("reconnected") { await h.transport.reconnectCount == 1 }
        #expect(h.controller.isActive)
        #expect(h.controller.deactivations == 0)
    }

    @Test func unpairEndsTheSessionInvalidatesTokenAndForgets() async throws {
        let h = Harness()
        let task = await h.run()
        defer { task.cancel() }
        await h.connected()
        await h.play()
        let id = try #require(h.controller.sessionID)
        try await h.registrar.registerUpdateToken("aa", forSessionID: id)
        await h.model.unpair()
        #expect(!h.controller.isActive)
        #expect(h.registrar.current().sessions.isEmpty)
        #expect(h.model.pairedMac == nil)
        #expect(h.model.attributes == nil)
        #expect(!h.model.isNowPlayingEnabled)
        #expect(await h.transport.unpairCount == 1)
    }

    @Test func userStopEndsTheSessionAndRemembersTheChoice() async {
        let h = Harness()
        let task = await h.run()
        defer { task.cancel() }
        await h.connected()
        await h.play()
        await h.model.stopNowPlaying()
        #expect(!h.controller.isActive)
        #expect(!h.model.isNowPlayingEnabled)
    }

    @Test func relaySaysSessionEnded() async {
        let h = Harness()
        let task = await h.run()
        defer { task.cancel() }
        await h.connected()
        await h.play()
        await h.transport.emit(.sessionEnded(.pairingRevoked))
        await eventually("ended") { !h.controller.isActive }
    }

    @Test func relayIssuedIdentifierIsUsedAndAChangeReplacesTheSession() async {
        let h = Harness()
        let task = await h.run()
        defer { task.cancel() }
        await h.connected()
        await h.transport.emit(.sessionAssigned("relay-1"))
        await h.transport.emit(.playback(message(revision: 1)))
        await eventually("active") { h.controller.isActive }
        #expect(h.controller.sessionID == "relay-1")
        await h.transport.emit(.sessionAssigned("relay-2"))
        await h.transport.emit(.playback(message(revision: 2)))
        await eventually("replaced") { h.controller.sessionID == "relay-2" }
        #expect(h.controller.deactivations == 1)
    }

    @Test func staleRevisionIsIgnored() async {
        let h = Harness()
        let task = await h.run()
        defer { task.cancel() }
        await h.connected()
        await h.play(revision: 10)
        await h.transport.emit(.playback(message(revision: 9, state: .stopped, track: nil)))
        await h.transport.emit(.playback(message(revision: 11, state: .paused)))
        await eventually("newer applied") { h.model.attributes?.revision == 11 }
        #expect(h.controller.deactivations == 0)
    }

    @Test func trackWithoutArtworkClearsThePreviousImage() async {
        let h = Harness()
        let task = await h.run()
        defer { task.cancel() }
        await h.connected()
        await h.transport.emit(.playback(message(revision: 1, track: track("a", artworkID: "x"))))
        await eventually("attributes") { h.model.attributes?.track?.id == "a" }
        await h.transport.emit(.playback(message(revision: 2, track: track("b"))))
        await eventually("attributes") { h.model.attributes?.track?.id == "b" }
        #expect(h.model.attributes?.track?.artworkID == nil)
        #expect(h.model.artwork == nil)
    }
}

// MARK: - Transport lifecycle (audit C3)

@MainActor
@Suite struct TransportRestartTests {
    @Test func cancelledConsumerStopsAndCanRestart() async {
        let h = Harness()
        let first = await h.run()
        await h.connected()
        #expect(h.model.isConsumingEvents)
        first.cancel()
        await first.value
        #expect(!h.model.isConsumingEvents)

        let second = await h.run()
        defer { second.cancel() }
        #expect(await h.transport.subscribeCount == 2)
        await h.transport.emit(.playback(message(revision: 1)))
        await eventually("delivered after restart") { h.model.attributes?.revision == 1 }
    }

    @Test func secondStartWhileRunningDoesNotSubscribeAgain() async {
        let h = Harness()
        let task = await h.run()
        defer { task.cancel() }
        await h.model.start()
        #expect(await h.transport.subscribeCount == 1)
    }

    @Test func restartPicksUpWhatHappenedWhileCancelled() async {
        let h = Harness()
        let first = await h.run()
        await h.connected()
        first.cancel()
        await first.value

        await h.transport.emit(.connection(.connected(macName: "Renamed Mac")))
        await h.transport.emit(.playback(message(revision: 5)))

        let second = await h.run()
        defer { second.cancel() }
        await eventually("connection replayed") { h.model.connection == .connected(macName: "Renamed Mac") }
        await eventually("playback replayed") { h.model.attributes?.revision == 5 }
    }

    @Test func connectionStateFollowsTheTransportAcrossARestart() async {
        let h = Harness()
        let first = await h.run()
        await h.connected()
        first.cancel()
        await first.value

        await h.transport.disconnect()

        let second = await h.run()
        defer { second.cancel() }
        await eventually("not stuck on Connected") { h.model.connection == .disconnected }
    }

    @Test func eachRunConnectsAndRepeatedConnectIsHarmless() async throws {
        let transport = MockTransport()
        let stream = await transport.subscribe()
        await transport.connect()
        await transport.connect()
        var iterator = stream.makeAsyncIterator()
        var connected = 0
        var playback = 0
        // Initial replay, connecting, connected, playback.
        for _ in 0..<4 {
            switch await iterator.next() {
            case .connection(.connected): connected += 1
            case .playback: playback += 1
            default: break
            }
        }
        #expect(connected == 1)
        #expect(playback == 1)
    }

    @Test func mockReconnectsAfterDisconnect() async throws {
        let transport = MockTransport()
        await transport.connect()
        await transport.disconnect()
        await #expect(throws: TransportError.notConnected) { _ = try await transport.send(RemoteCommand(kind: .pause)) }
        await transport.reconnect()
        let ack = try await transport.send(RemoteCommand(kind: .pause))
        #expect(ack.accepted)
    }

    @Test func subscribingAgainFinishesTheOldStream() async {
        let transport = MockTransport()
        let old = await transport.subscribe()
        _ = await transport.subscribe()
        var iterator = old.makeAsyncIterator()
        _ = await iterator.next()   // The initial state.
        #expect(await iterator.next() == nil)
    }
}

// MARK: - Failed activation (audit C4)

@MainActor
@Suite struct ActivationRecoveryTests {
    @Test func failedActivationRetriesOnTheNextUpdate() async {
        let h = Harness()
        h.controller.failActivation = true
        let task = await h.run()
        defer { task.cancel() }
        await h.connected()
        await h.transport.emit(.playback(message(revision: 1)))
        await eventually("attempted") { h.controller.activations.count == 1 }
        #expect(!h.controller.isActive)

        h.controller.failActivation = false
        await h.transport.emit(.playback(message(revision: 2)))
        await eventually("recovered") { h.controller.isActive }
        #expect(h.controller.activations.last?.revision == 2, "the newest state must not be lost")
    }

    @Test func failedActivationRecoversOnForeground() async {
        let h = Harness()
        h.controller.failActivation = true
        let task = await h.run()
        defer { task.cancel() }
        await h.connected()
        await h.transport.emit(.playback(message(revision: 3)))
        await eventually("attempted") { h.controller.activations.count == 1 }

        h.controller.failActivation = false
        await h.model.sceneDidBecomeActive()
        #expect(h.controller.isActive)
        #expect(h.controller.activations.last?.revision == 3)
    }

    @Test func repeatedFailureIsLoggedOnce() async {
        let h = Harness()
        h.controller.failActivation = true
        let task = await h.run()
        defer { task.cancel() }
        await h.connected()
        await h.transport.emit(.playback(message(revision: 1)))
        await h.transport.emit(.playback(message(revision: 2)))
        await eventually("attempted twice") { h.controller.activations.count == 2 }
        #expect(h.model.log.filter { $0.message.contains("Now Playing failed") }.count == 1)
    }

    @Test func foregroundDoesNotActivateWhenPlaybackHasEnded() async {
        let h = Harness()
        let task = await h.run()
        defer { task.cancel() }
        await h.connected()
        await h.transport.emit(.playback(message(revision: 1, state: .stopped, track: nil)))
        await eventually("applied") { h.model.attributes?.revision == 1 }
        await h.model.sceneDidBecomeActive()
        #expect(h.controller.activations.isEmpty)
    }

    @Test func foregroundDoesNotActivateWithoutALink() async {
        let h = Harness()
        let task = await h.run()
        defer { task.cancel() }
        await h.connected()
        await h.transport.emit(.playback(message(revision: 1)))
        await eventually("active") { h.controller.isActive }
        await h.transport.disconnect()
        await eventually("ended") { !h.controller.isActive }
        await h.model.sceneDidBecomeActive()
        #expect(h.controller.activations.count == 1)
    }

    @Test func foregroundReassertsPrimaryOnAnExistingSession() async {
        let h = Harness()
        let task = await h.run()
        defer { task.cancel() }
        await h.connected()
        await h.play()
        let before = h.controller.primaryRequests
        await h.model.sceneDidBecomeActive()
        #expect(h.controller.primaryRequests == before + 1)
    }

    @Test func coldLaunchWithNowPlayingEnabledActivates() async {
        let h = Harness(nowPlayingEnabled: true)
        let task = await h.run()
        defer { task.cancel() }
        #expect(await h.transport.connectCount == 1)
        await h.connected()
        await h.play()
        #expect(h.controller.activations.count == 1)
    }

    @Test func unpairedAppDoesNotConnect() async {
        let h = Harness(paired: false)
        let task = await h.run()
        defer { task.cancel() }
        #expect(await h.transport.connectCount == 0)
    }
}
