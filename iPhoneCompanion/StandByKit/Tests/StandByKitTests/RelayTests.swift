import Foundation
import Testing
@testable import StandByKit

// MARK: - Doubles

/// Scripted HTTP. Each response is consumed in order; the last one repeats.
actor FakeHTTP: HTTPSending {
    struct Reply: Sendable {
        var status = 200
        var body = Data()
        var headers: [String: String] = [:]
        var error: URLError.Code?
    }

    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [Reply] = [Reply()]) { self.replies = replies }

    func script(_ newReplies: [Reply]) { replies = newReplies }

    func send(_ request: URLRequest, maxBytes: Int?) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let reply = replies.count > 1 ? replies.removeFirst() : replies[0]
        if let code = reply.error { throw URLError(code) }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/2", headerFields: reply.headers)!
        return (reply.body, response)
    }
}

extension FakeHTTP.Reply {
    static func json(_ value: some Encodable, status: Int = 200) -> Self {
        Self(status: status, body: try! StandByWire.makeEncoder().encode(value))
    }
    static func failure(_ code: ErrorCode, status: Int, retryAfter: TimeInterval? = nil) -> Self {
        json(ErrorResponse(error: ProtocolError(code, retryAfter: retryAfter)), status: status)
    }
    static var noContent: Self { Self(status: 204) }
    static func network(_ code: URLError.Code) -> Self { Self(error: code) }
}

let relayConfiguration = RelayConfiguration(baseURL: URL(string: "https://relay.example.com")!)!
let testCredential = RelayCredential(configuration: relayConfiguration, pairingID: "p1", token: "secret-token", mac: PairedMac(id: "m", name: "Studio Mac"))
let testDevice = DeviceIdentity(id: "d", name: "Test iPhone", kind: .iPhone)

private func client(_ http: FakeHTTP) -> RelayClient { RelayClient(credential: testCredential, http: http) }

private func bodyOf<T: Decodable>(_ request: URLRequest, as type: T.Type) throws -> T {
    try StandByWire.makeDecoder().decode(type, from: try #require(request.httpBody))
}

private func sessionAttributes() -> MacPlaybackAttributes {
    MacPlaybackAttributes(mac: PairedMac(id: "m", name: "Studio Mac"), message: message(revision: 7), sessionID: "s1")
}

/// A `sleep` that returns at once and remembers what it was asked for.
final class RecordingSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TimeInterval] = []
    private var stopAfter: Int?
    var recorded: [TimeInterval] { lock.withLock { values } }

    /// Throws once `count` sleeps have happened, ending a polling loop.
    init(stopAfter count: Int? = nil) { stopAfter = count }

    func sleep(_ seconds: TimeInterval) async throws {
        let shouldStop = lock.withLock { () -> Bool in
            values.append(seconds)
            if let stopAfter, values.count >= stopAfter { return true }
            return false
        }
        if shouldStop { throw CancellationError() }
        await Task.yield()
    }
}

// MARK: - Configuration

@Suite struct RelayConfigurationTests {
    @Test func requiresHTTPS() {
        #expect(RelayConfiguration(baseURL: URL(string: "https://relay.example.com")!) != nil)
        #expect(RelayConfiguration(baseURL: URL(string: "http://relay.example.com")!) == nil)
        #expect(RelayConfiguration(baseURL: URL(string: "ftp://relay.example.com")!) == nil)
    }

    @Test func allowsLoopbackForADevelopmentRelay() {
        #expect(RelayConfiguration(baseURL: URL(string: "http://127.0.0.1:8787")!) != nil)
        #expect(RelayConfiguration(baseURL: URL(string: "http://localhost:8787")!) != nil)
    }
}

// MARK: - Commands

@Suite struct RelayCommandTests {
    let ackBody: @Sendable (UUID) -> FakeHTTP.Reply = { .json(CommandResponse(ack: .accepted($0, revision: 43))) }

    @Test func postsTheSharedProtocolShape() async throws {
        let command = RemoteCommand(kind: .pause, issuedAt: Date(timeIntervalSince1970: 1_000))
        let http = FakeHTTP([ackBody(command.id)])
        let ack = try await client(http).send(command)
        #expect(ack.accepted)
        #expect(ack.revision == 43)

        let request = try #require(await http.requests.first)
        #expect(request.url?.absoluteString == "https://relay.example.com/v1/commands")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == command.id.uuidString)
        #expect(request.value(forHTTPHeaderField: "X-Protocol-Version") == "1")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.timeoutInterval == RelayClient.commandTimeout)
        #expect(try bodyOf(request, as: CommandRequest.self).command == command)
    }

    @Test func rejectionFromTheMacIsReturnedForTheCallerToReport() async throws {
        let command = RemoteCommand(kind: .next)
        let http = FakeHTTP([.json(CommandResponse(ack: .rejected(command.id, revision: 1, ProtocolError(.noCurrentTrack))))])
        let ack = try await client(http).send(command)
        #expect(!ack.accepted)
        #expect(ack.error?.code == .noCurrentTrack)
    }

    @Test func anAckForAnotherCommandIsNotBelieved() async {
        let http = FakeHTTP([.json(CommandResponse(ack: .accepted(UUID(), revision: 1)))])
        await #expect(throws: TransportError.malformedResponse) {
            _ = try await client(http).send(RemoteCommand(kind: .play))
        }
    }

    @Test func macUnreachableMapsFrom504() async {
        let http = FakeHTTP([.failure(.macUnreachable, status: 504)])
        await #expect(throws: TransportError.macUnreachable) { _ = try await client(http).send(RemoteCommand(kind: .play)) }
    }

    @Test func aTimeoutMeansTheMacDidNotAnswer() async {
        let http = FakeHTTP([.network(.timedOut)])
        await #expect(throws: TransportError.macUnreachable) { _ = try await client(http).send(RemoteCommand(kind: .play)) }
    }

    @Test func revokedPairingMapsFrom401() async {
        let http = FakeHTTP([.failure(.pairingRevoked, status: 401)])
        await #expect(throws: TransportError.pairingRevoked) { _ = try await client(http).send(RemoteCommand(kind: .play)) }
    }

    @Test func rateLimitCarriesTheRetryTime() async {
        let http = FakeHTTP([.failure(.rateLimited, status: 429, retryAfter: 60)])
        await #expect(throws: TransportError.rateLimited(retryAfter: 60)) { _ = try await client(http).send(RemoteCommand(kind: .play)) }
    }

    @Test func offlineIsANetworkError() async {
        let http = FakeHTTP([.network(.notConnectedToInternet)])
        await #expect(throws: TransportError.self) { _ = try await client(http).send(RemoteCommand(kind: .play)) }
    }

    @Test func noCredentialMeansNoRequest() async {
        let http = FakeHTTP()
        let unauthenticated = RelayClient(configuration: relayConfiguration, http: http, token: { nil })
        await #expect(throws: TransportError.notPaired) { _ = try await unauthenticated.send(RemoteCommand(kind: .play)) }
        #expect(await http.requests.isEmpty)
    }

    @Test func aRelaySpeakingAnotherVersionIsRefused() async {
        var reply = ackBody(UUID())
        reply.headers = ["X-Protocol-Version": "2"]
        let http = FakeHTTP([reply])
        await #expect(throws: TransportError.commandRejected(.unsupportedProtocolVersion)) {
            _ = try await client(http).send(RemoteCommand(kind: .play))
        }
    }

    @Test func aBaseURLWithATrailingSlashStillBuildsCleanPaths() async throws {
        let config = try #require(RelayConfiguration(baseURL: URL(string: "https://relay.example.com/")!))
        let http = FakeHTTP([.json(RelaySessionResponse(session: nil))])
        _ = try await RelayClient(configuration: config, http: http, token: { "t" }).fetchSession()
        #expect(await http.requests.first?.url?.absoluteString == "https://relay.example.com/v1/session")
    }
}

// MARK: - The extension's command path (audit B1, B2)

@Suite struct ExtensionCommandPathTests {
    private func container() -> SharedContainer {
        SharedContainer(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory))
    }

    @Test func productionPathSendsDirectlyAndChangesNothingOnScreen() async throws {
        let http = FakeHTTP()
        let services = ExtensionServices.make(container: container(), credentials: InMemoryCredentialStore(testCredential), http: http, allowMock: false)
        #expect(services.usesRelay)
        let attributes = sessionAttributes()
        let date = Date(timeIntervalSince1970: 500)
        // Answer with an ack for whatever id was generated.
        let handler = RelayCommandHandler(sender: AckingSender())
        #expect(try await handler.perform(.next, on: attributes, at: date) == nil, "the Mac's own state must drive the screen")

        _ = try? await services.commands.perform(.pause, on: attributes, at: date)
        let sent = try #require(await http.requests.first)
        #expect(sent.url?.path() == "/v1/commands")
        #expect(try bodyOf(sent, as: CommandRequest.self).command.kind == .pause)
        #expect(try bodyOf(sent, as: CommandRequest.self).command.issuedAt == date)
    }

    @Test func aRefusedCommandThrowsSoTheSystemKnows() async {
        let handler = RelayCommandHandler(sender: AckingSender(refusing: .musicNotRunning))
        await #expect(throws: TransportError.commandRejected(.musicNotRunning)) {
            _ = try await handler.perform(.play, on: sessionAttributes(), at: Date())
        }
    }

    @Test func productionNextOnARealTrackIsNotGuessedFromTheMockLibrary() async throws {
        var attributes = sessionAttributes()
        attributes.track?.id = "pid:542CEB17C137B39E"
        let handler = RelayCommandHandler(sender: AckingSender())
        #expect(try await handler.perform(.next, on: attributes, at: Date()) == nil)
    }

    @Test func aFailedSendPropagates() async {
        let handler = RelayCommandHandler(sender: AckingSender(failing: .macUnreachable))
        await #expect(throws: TransportError.macUnreachable) {
            _ = try await handler.perform(.next, on: sessionAttributes(), at: Date())
        }
    }

    @Test func mockRouteStillRespondsForDevelopment() async throws {
        let services = ExtensionServices.make(container: container(), credentials: InMemoryCredentialStore(), allowMock: true)
        #expect(!services.usesRelay)
        var attributes = sessionAttributes()
        attributes.track = SessionTrack(id: "mock-1", title: "T", artist: "A", album: "B", duration: 100, artworkID: "mock-art-1")
        let result = try #require(try await services.commands.perform(.next, on: attributes, at: Date()))
        #expect(result.track?.id == "mock-2")
    }

    @Test func aCommandLogThatCantBeWrittenDoesNotFailTheTap() async throws {
        var attributes = sessionAttributes()
        attributes.track = SessionTrack(id: "mock-1", title: "T", artist: "A", album: "B", duration: 100, artworkID: "mock-art-1")
        let result = try await MockCommandHandler(container: unwritableContainer()).perform(.next, on: attributes, at: Date())
        #expect(result?.track?.id == "mock-2")
    }

    @Test func releaseBuildWithNoPairingFailsInsteadOfFakingIt() async {
        let services = ExtensionServices.make(container: container(), credentials: InMemoryCredentialStore(), allowMock: false)
        await #expect(throws: TransportError.notPaired) {
            _ = try await services.commands.perform(.play, on: sessionAttributes(), at: Date())
        }
    }

    @Test func anUnreadableKeychainNeverBecomesTheMock() async {
        let services = ExtensionServices.make(container: container(), credentials: FailingCredentialStore(), allowMock: true)
        await #expect(throws: TransportError.notPaired) {
            _ = try await services.commands.perform(.play, on: sessionAttributes(), at: Date())
        }
    }
}

/// Inside a regular file, so no folder can ever be made there.
func unwritableContainer() -> SharedContainer {
    let blocker = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    FileManager.default.createFile(atPath: blocker.path(), contents: Data())
    return SharedContainer(directory: blocker.appending(path: "StandBy", directoryHint: .isDirectory), isShared: false)
}

private struct AckingSender: CommandSender {
    var refusing: ErrorCode?
    var failing: TransportError?
    func send(_ command: RemoteCommand) async throws -> CommandAck {
        if let failing { throw failing }
        if let refusing { return .rejected(command.id, revision: 1, ProtocolError(refusing)) }
        return .accepted(command.id, revision: 1)
    }
}

private struct FailingCredentialStore: CredentialStore {
    func load() throws -> RelayCredential? { throw CredentialStoreError.keychain(-25308) }
    func save(_ credential: RelayCredential) throws {}
    func delete() throws {}
}

// MARK: - Pairing and credentials

@Suite struct RelayPairingTests {
    private func transport(_ http: FakeHTTP, store: any CredentialStore, sleeper: RecordingSleeper = RecordingSleeper(stopAfter: 1)) -> RelayTransport {
        RelayTransport(configuration: relayConfiguration, credentials: store, http: http, device: { testDevice }, sleep: { try await sleeper.sleep($0) }, jitter: { 0 })
    }

    @Test func claimStoresTheCredentialSecurely() async throws {
        let grant = PairingGrant(pairingID: "p", phoneToken: "tok", mac: PairedMac(id: "m", name: "Studio Mac"))
        let http = FakeHTTP([.json(grant)])
        let store = InMemoryCredentialStore()
        let mac = try await transport(http, store: store).pair(code: try #require(PairingCode("472915")))
        #expect(mac.name == "Studio Mac")
        #expect(store.load()?.token == "tok")

        let request = try #require(await http.requests.first)
        #expect(request.url?.path() == "/v1/pair/claim")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil, "claiming needs no credential")
        let claim = try bodyOf(request, as: PairingClaim.self)
        #expect(claim.code == "472915")
        #expect(claim.deviceName == "Test iPhone")
        #expect(claim.device == testDevice)
    }

    @Test func aWrongCodeIsRejected() async throws {
        let http = FakeHTTP([.init(status: 404)])
        let store = InMemoryCredentialStore()
        await #expect(throws: TransportError.pairingRejected) {
            _ = try await transport(http, store: store).pair(code: try #require(PairingCode("000001")))
        }
        #expect(store.load() == nil)
    }

    @Test func anUnknownErrorCodeFromClaimIsARejection() async throws {
        let http = FakeHTTP([.failure("unknown_or_expired_code", status: 404)])
        await #expect(throws: TransportError.pairingRejected) {
            _ = try await transport(http, store: InMemoryCredentialStore()).pair(code: try #require(PairingCode("000001")))
        }
    }

    @Test func tooManyAttemptsIsReported() async throws {
        let http = FakeHTTP([.failure(.rateLimited, status: 429, retryAfter: 60)])
        await #expect(throws: TransportError.rateLimited(retryAfter: 60)) {
            _ = try await transport(http, store: InMemoryCredentialStore()).pair(code: try #require(PairingCode("123456")))
        }
    }

    @Test func unpairTellsTheRelayAndForgetsEvenIfTheRelayIsDown() async throws {
        let http = FakeHTTP([.network(.notConnectedToInternet)])
        let store = InMemoryCredentialStore(testCredential)
        await transport(http, store: store).unpair()
        let request = try #require(await http.requests.first)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path() == "/v1/pairing")
        #expect(store.load() == nil)
    }

    @Test func credentialRoundTripsThroughJSON() throws {
        let data = try JSONEncoder().encode(testCredential)
        #expect(try JSONDecoder().decode(RelayCredential.self, from: data) == testCredential)
    }
}

// MARK: - Push tokens

@Suite struct RelayTokenTests {
    private func container() -> SharedContainer {
        SharedContainer(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory))
    }

    @Test func registersAndInvalidatesWithTheRelay() async throws {
        let http = FakeHTTP([.noContent])
        let registrar = RelayPushTokenRegistrar(container: container(), client: { client(http) })
        try await registrar.registerStartToken("aa")
        try await registrar.registerUpdateToken("bb", forSessionID: "s/1")
        #expect(registrar.current() == PushTokens(pushToStart: "aa", sessions: ["s/1": "bb"]))
        try await registrar.invalidate(sessionID: "s/1")
        #expect(registrar.current().sessions.isEmpty)

        let requests = await http.requests
        #expect(requests[0].url?.path() == "/v1/tokens/start")
        #expect(try bodyOf(requests[0], as: StartTokenRegistration.self).pushToStartToken == "aa")
        #expect(requests[1].url?.path() == "/v1/tokens/session")
        #expect(try bodyOf(requests[1], as: SessionTokenRegistration.self) == SessionTokenRegistration(sessionID: "s/1", pushToken: "bb"))
        #expect(requests[2].httpMethod == "DELETE")
        #expect(requests[2].url?.absoluteString == "https://relay.example.com/v1/tokens/session/s%2F1")
    }

    @Test func tokensArrivingBeforePairingAreUploadedAfterwards() async throws {
        let http = FakeHTTP([.noContent])
        let box = ClientBox()
        let registrar = RelayPushTokenRegistrar(container: container(), client: { box.client })
        try await registrar.registerStartToken("aa")
        #expect(await http.requests.isEmpty)
        box.client = client(http)
        try await registrar.uploadStored()
        #expect(await http.requests.count == 1)
    }

    @Test func aFailedUploadIsHeldForRetry() async throws {
        let http = FakeHTTP([.network(.notConnectedToInternet)])
        let registrar = RelayPushTokenRegistrar(container: container(), client: { client(http) })
        await #expect(throws: TransportError.self) { try await registrar.registerUpdateToken("bb", forSessionID: "s") }
        #expect(registrar.current().sessions["s"] == "bb")
        await http.script([.noContent])
        try await registrar.uploadStored()
        #expect(await http.requests.count == 2)
    }

    @Test func relayStillHearsWhenTheLocalCopyCantBeWritten() async throws {
        let http = FakeHTTP([.noContent])
        let registrar = RelayPushTokenRegistrar(container: unwritableContainer(), client: { client(http) })
        try await registrar.registerUpdateToken("bb", forSessionID: "s")
        try await registrar.invalidate(sessionID: "s")
        #expect(await http.requests.count == 2)
    }

    @Test func mockRegistrarHasNothingToUpload() async throws {
        try await MockPushTokenRegistrar(container: container()).uploadStored()
    }
}

private final class ClientBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: RelayClient?
    var client: RelayClient? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

// MARK: - Authoritative state, reconnection and recovery

@Suite struct RelayTransportTests {
    private func make(_ http: FakeHTTP, sleeper: RecordingSleeper, store: any CredentialStore = InMemoryCredentialStore(testCredential)) -> RelayTransport {
        RelayTransport(configuration: relayConfiguration, credentials: store, http: http, device: { testDevice }, sleep: { try await sleeper.sleep($0) }, jitter: { 0 })
    }

    /// Reads until `count` events have arrived.
    private func collect(_ stream: AsyncStream<TransportEvent>, count: Int) async -> [String] {
        var seen: [String] = []
        for await event in stream {
            seen.append(Self.describe(event))
            if seen.count == count { break }
        }
        return seen
    }

    private static func describe(_ event: TransportEvent) -> String {
        switch event {
        case .connection(.disconnected): "disconnected"
        case .connection(.connecting): "connecting"
        case .connection(.connected(let name)): "connected:\(name)"
        case .connection(.reconnecting): "reconnecting"
        case .connection(.failed): "failed"
        case .playback(let message): "playback:\(message.revision)"
        case .sessionAssigned(let id): "assigned:\(id)"
        case .sessionEnded(let reason): "ended:\(reason.rawValue)"
        }
    }

    private let live = FakeHTTP.Reply.json(RelaySessionResponse(session: RelaySession(sessionID: "s1", playback: message(revision: 42))))

    @Test func connectAppliesTheAuthoritativeSession() async throws {
        let http = FakeHTTP([live])
        let transport = make(http, sleeper: RecordingSleeper(stopAfter: 1))
        let stream = await transport.subscribe()
        await transport.connect()
        let events = await collect(stream, count: 5)
        #expect(events == ["disconnected", "connecting", "connected:Studio Mac", "assigned:s1", "playback:42"])
        let request = try #require(await http.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")
    }

    @Test func anUnchangedSessionIsNotReemitted() async {
        let http = FakeHTTP([live, live, .json(RelaySessionResponse(session: RelaySession(sessionID: "s1", playback: message(revision: 43))))])
        let transport = make(http, sleeper: RecordingSleeper(stopAfter: 3))
        let stream = await transport.subscribe()
        await transport.connect()
        let events = await collect(stream, count: 6)
        #expect(events.suffix(2) == ["playback:42", "playback:43"])
    }

    @Test func aNetworkDropReconnectsWithBackoffWithoutEndingTheSession() async {
        let down = FakeHTTP.Reply.network(.notConnectedToInternet)
        let http = FakeHTTP([live, down, down, down, live])
        let sleeper = RecordingSleeper(stopAfter: 5)
        let transport = make(http, sleeper: sleeper)
        let stream = await transport.subscribe()
        await transport.connect()
        let events = await collect(stream, count: 7)
        #expect(events == ["disconnected", "connecting", "connected:Studio Mac", "assigned:s1", "playback:42", "reconnecting", "connected:Studio Mac"])
        #expect(!events.contains { $0.hasPrefix("ended") })
        #expect(sleeper.recorded == [5, 1, 2, 4, 5], "poll, then 1, 2, 4 s of backoff, then polling resumes")
    }

    @Test func theRelayReportingNoSessionEndsIt() async {
        let http = FakeHTTP([live, .json(RelaySessionResponse(session: nil))])
        let transport = make(http, sleeper: RecordingSleeper(stopAfter: 2))
        let stream = await transport.subscribe()
        await transport.connect()
        let events = await collect(stream, count: 6)
        #expect(events.last == "ended:playbackEnded")
    }

    @Test func noSessionFromTheStartIsNotAnEnding() async {
        let http = FakeHTTP([.json(RelaySessionResponse(session: nil))])
        let transport = make(http, sleeper: RecordingSleeper(stopAfter: 1))
        let stream = await transport.subscribe()
        await transport.connect()
        let events = await collect(stream, count: 3)
        #expect(events == ["disconnected", "connecting", "connected:Studio Mac"])
    }

    @Test func aRevokedTokenEndsThePairing() async {
        let http = FakeHTTP([.failure(.pairingRevoked, status: 401)])
        let store = InMemoryCredentialStore(testCredential)
        let transport = make(http, sleeper: RecordingSleeper(stopAfter: 1), store: store)
        let stream = await transport.subscribe()
        await transport.connect()
        let events = await collect(stream, count: 4)
        #expect(events.suffix(2) == ["failed", "ended:pairingRevoked"])
        #expect(store.load() == nil)
    }

    @Test func connectingWithoutACredentialFailsCleanly() async {
        let http = FakeHTTP()
        let transport = make(http, sleeper: RecordingSleeper(stopAfter: 1), store: InMemoryCredentialStore())
        let stream = await transport.subscribe()
        await transport.connect()
        #expect(await collect(stream, count: 2) == ["disconnected", "failed"])
        #expect(await http.requests.isEmpty)
    }

    @Test func aRestartedConsumerIsBroughtUpToDate() async {
        let http = FakeHTTP([live])
        let transport = make(http, sleeper: RecordingSleeper(stopAfter: 1))
        let first = await transport.subscribe()
        await transport.connect()
        _ = await collect(first, count: 5)

        let second = await transport.subscribe()
        #expect(await collect(second, count: 3) == ["connected:Studio Mac", "assigned:s1", "playback:42"])
    }

    @Test func reconnectDoesNotReportADisconnection() async {
        let http = FakeHTTP([live])
        let transport = make(http, sleeper: RecordingSleeper(stopAfter: 1))
        let stream = await transport.subscribe()
        await transport.connect()
        await transport.reconnect()
        let events = await collect(stream, count: 5)
        #expect(events.filter { $0 == "disconnected" }.count == 1, "only the initial replay")
    }

    @Test func artworkIsValidatedAndUsesTheRelayEndpoint() async throws {
        let id = String(repeating: "b", count: 64)
        let image = encodedImage(.jpeg)
        let http = FakeHTTP([FakeHTTP.Reply(status: 200, body: image, headers: ["Content-Type": "image/jpeg"])])
        let transport = make(http, sleeper: RecordingSleeper(stopAfter: 1))
        #expect(try await transport.artwork(id: id) == image)
        let request = try #require(await http.requests.first)
        #expect(request.url?.path() == "/v1/artwork/\(id)")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")
    }

    @Test func artworkThatIsNotAnImageIsRefused() async {
        let id = String(repeating: "b", count: 64)
        let http = FakeHTTP([FakeHTTP.Reply(status: 200, body: Data("<html>".utf8), headers: ["Content-Type": "text/html"])])
        await #expect(throws: TransportError.artworkUnavailable) { _ = try await client(http).fetch(id: id) }
    }

    @Test func artworkURLOnAnotherHostIsNeverRequested() async {
        let http = FakeHTTP()
        await #expect(throws: TransportError.artworkUnavailable) {
            _ = try await client(http).fetch(url: URL(string: "https://evil.example.com/a.png")!)
        }
        #expect(await http.requests.isEmpty, "the bearer token must not leave for another host")
    }

    @Test func backoffIsBoundedAndJitterOnlyLengthens() {
        let timing = RelayTransport.Timing()
        #expect(timing.backoff(afterFailures: 1, jitter: 0) == 1)
        #expect(timing.backoff(afterFailures: 2, jitter: 0) == 2)
        #expect(timing.backoff(afterFailures: 6, jitter: 0) == 30)
        #expect(timing.backoff(afterFailures: 100, jitter: 1) == 30)
        #expect(timing.backoff(afterFailures: 2, jitter: 1) == 2.5)
    }
}

// MARK: - App integration

@MainActor
@Suite struct RelayAppModelTests {
    @Test func revocationForgetsThePairing() async {
        let h = Harness()
        let task = await h.run()
        defer { task.cancel() }
        await h.connected()
        await h.play()
        await h.transport.emit(.sessionEnded(.pairingRevoked))
        await eventually("pairing forgotten") { h.model.pairedMac == nil }
        #expect(!h.controller.isActive)
        #expect(!h.model.isNowPlayingEnabled)
    }

    @Test func aSessionEndedByTheRelayIsNotRepublishedOnForeground() async {
        let h = Harness()
        let task = await h.run()
        defer { task.cancel() }
        await h.connected()
        await h.play()
        await h.transport.emit(.sessionEnded(.playbackEnded))
        await eventually("ended") { !h.controller.isActive }
        await eventually("cleared") { h.model.attributes == nil }
        await h.model.sceneDidBecomeActive()
        #expect(h.controller.activations.count == 1)
    }

    @Test func commandsCarryTheirIssueTime() async throws {
        let h = Harness()
        let task = await h.run()
        defer { task.cancel() }
        await h.model.send(.pause)
        let sent = try #require(await h.transport.sent.first)
        #expect(sent.kind == .pause)
        #expect(sent.issuedAt == h.clock.now)
    }
}
