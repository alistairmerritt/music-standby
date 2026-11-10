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

let studioMac = PairedMac(id: "m", name: "Studio Mac")

func sessionState(_ id: String?, revision: UInt64 = 42, macConnected: Bool = true) -> SessionState {
    SessionState(sessionID: id, mac: studioMac, macConnected: macConnected, playback: id == nil ? nil : message(revision: revision), attributes: nil)
}

/// What a pairing reported while it waited.
final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [PairingProgress] = []
    var all: [PairingProgress] { lock.withLock { values } }
    func append(_ value: PairingProgress) { lock.withLock { values.append(value) } }
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
        let ack = try await client(http).send(command, sessionID: "s1")
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
        let ack = try await client(http).send(command, sessionID: "s1")
        #expect(!ack.accepted)
        #expect(ack.error?.code == .noCurrentTrack)
    }

    @Test func anAckForAnotherCommandIsNotBelieved() async {
        let http = FakeHTTP([.json(CommandResponse(ack: .accepted(UUID(), revision: 1)))])
        await #expect(throws: TransportError.malformedResponse) {
            _ = try await client(http).send(RemoteCommand(kind: .play), sessionID: "s1")
        }
    }

    @Test func macUnreachableMapsFrom504() async {
        let http = FakeHTTP([.failure(.macUnreachable, status: 504)])
        await #expect(throws: TransportError.macUnreachable) { _ = try await client(http).send(RemoteCommand(kind: .play), sessionID: "s1") }
    }

    @Test func aTimeoutMeansTheMacDidNotAnswer() async {
        let http = FakeHTTP([.network(.timedOut)])
        await #expect(throws: TransportError.macUnreachable) { _ = try await client(http).send(RemoteCommand(kind: .play), sessionID: "s1") }
    }

    @Test func revokedPairingMapsFrom401() async {
        let http = FakeHTTP([.failure(.pairingRevoked, status: 401)])
        await #expect(throws: TransportError.pairingRevoked) { _ = try await client(http).send(RemoteCommand(kind: .play), sessionID: "s1") }
    }

    @Test func rateLimitCarriesTheRetryTime() async {
        let http = FakeHTTP([.failure(.rateLimited, status: 429, retryAfter: 60)])
        await #expect(throws: TransportError.rateLimited(retryAfter: 60)) { _ = try await client(http).send(RemoteCommand(kind: .play), sessionID: "s1") }
    }

    @Test func offlineIsANetworkError() async {
        let http = FakeHTTP([.network(.notConnectedToInternet)])
        await #expect(throws: TransportError.self) { _ = try await client(http).send(RemoteCommand(kind: .play), sessionID: "s1") }
    }

    @Test func noCredentialMeansNoRequest() async {
        let http = FakeHTTP()
        let unauthenticated = RelayClient(configuration: relayConfiguration, http: http, token: { nil })
        await #expect(throws: TransportError.notPaired) { _ = try await unauthenticated.send(RemoteCommand(kind: .play), sessionID: "s1") }
        #expect(await http.requests.isEmpty)
    }

    @Test func aRelaySpeakingAnotherVersionIsRefused() async {
        var reply = ackBody(UUID())
        reply.headers = ["X-Protocol-Version": "2"]
        let http = FakeHTTP([reply])
        await #expect(throws: TransportError.commandRejected(.unsupportedProtocolVersion)) {
            _ = try await client(http).send(RemoteCommand(kind: .play), sessionID: "s1")
        }
    }

    @Test func aCommandForAnEndedSessionIsRefusedNotRetried() async {
        let http = FakeHTTP([.failure(.sessionMismatch, status: 409)])
        await #expect(throws: TransportError.commandRejected(.sessionMismatch)) {
            _ = try await client(http).send(RemoteCommand(kind: .next), sessionID: "old")
        }
        #expect(await http.requests.count == 1)
    }

    @Test func theRelaysUnauthorisedCodeEndsThePairing() async {
        let http = FakeHTTP([.failure(.unauthorized, status: 401)])
        await #expect(throws: TransportError.pairingRevoked) { _ = try await client(http).fetchSession() }
    }

    @Test func endingASessionNamesIt() async throws {
        let http = FakeHTTP([.noContent])
        try await client(http).endSession(sessionID: "s1")
        let request = try #require(await http.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path() == "/v1/session/end")
        #expect(try bodyOf(request, as: SessionEndRequest.self) == SessionEndRequest(sessionID: "s1"))
    }

    @Test func aBaseURLWithATrailingSlashStillBuildsCleanPaths() async throws {
        let config = try #require(RelayConfiguration(baseURL: URL(string: "https://relay.example.com/")!))
        let http = FakeHTTP([.json(sessionState(nil))])
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
        let body = try bodyOf(sent, as: CommandRequest.self)
        #expect(body.command.kind == .pause)
        #expect(body.command.issuedAt == date)
        #expect(body.sessionID == "s1", "the session on screen, so the relay can refuse a stale one")
        #expect(sent.value(forHTTPHeaderField: "Idempotency-Key") == body.command.id.uuidString)
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

    @Test func theExtensionRefusesArtworkTooLargeForItsMemoryLimit() async throws {
        let image = encodedImage(.jpeg, width: 900, height: 900)
        let http = FakeHTTP([FakeHTTP.Reply(status: 200, body: image, headers: ["Content-Type": "image/jpeg"])])
        let services = ExtensionServices.make(container: container(), credentials: InMemoryCredentialStore(testCredential), http: http, allowMock: false)
        await #expect(throws: TransportError.artworkUnavailable) {
            _ = try await services.artwork.resolve(id: String(repeating: "d", count: 64), remoteURL: nil)
        }
    }

    @Test func theExtensionAcceptsTypicalAlbumArt() async throws {
        let image = encodedImage(.jpeg, width: 600, height: 600)
        let http = FakeHTTP([FakeHTTP.Reply(status: 200, body: image, headers: ["Content-Type": "image/jpeg"])])
        let services = ExtensionServices.make(container: container(), credentials: InMemoryCredentialStore(testCredential), http: http, allowMock: false)
        #expect(try await services.artwork.resolve(id: String(repeating: "e", count: 64), remoteURL: nil) == image)
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
    func send(_ command: RemoteCommand, sessionID: String) async throws -> CommandAck {
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
    private let claim = PairingClaimResponse(claimID: "c1", claimSecret: "msb1.claim.p.secret", expiresAt: Date(timeIntervalSince1970: 2_000), mac: studioMac)
    private var approved: FakeHTTP.Reply {
        .json(PairingClaimStatus(status: .approved, pairingID: "p", phoneToken: "tok", mac: studioMac))
    }

    private func transport(_ http: FakeHTTP, store: any CredentialStore, sleeper: RecordingSleeper = RecordingSleeper(), now: Date = Date(timeIntervalSince1970: 1_000)) -> RelayTransport {
        RelayTransport(configuration: relayConfiguration, credentials: store, http: http, device: { testDevice }, now: { now }, sleep: { try await sleeper.sleep($0) }, jitter: { 0 })
    }

    @Test func aClaimWaitsForTheMacThenStoresTheCredential() async throws {
        let http = FakeHTTP([.json(claim, status: 202), .json(PairingClaimStatus(status: .pending)), approved])
        let store = InMemoryCredentialStore()
        let sleeper = RecordingSleeper()
        let heard = ProgressLog()
        let mac = try await transport(http, store: store, sleeper: sleeper).pair(code: try #require(PairingCode("472915"))) { heard.append($0) }
        #expect(mac == studioMac)
        #expect(heard.all == [.waitingForApproval(studioMac)])
        #expect(store.load() == RelayCredential(configuration: relayConfiguration, pairingID: "p", token: "tok", mac: studioMac))
        #expect(sleeper.recorded == [2, 2], "a claim poll every 2 s (API-v1 §4)")

        let requests = await http.requests
        #expect(requests[0].httpMethod == "POST")
        #expect(requests[0].url?.path() == "/v1/pairing/claim")
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == nil, "claiming needs no credential")
        #expect(try bodyOf(requests[0], as: PairingClaimRequest.self) == PairingClaimRequest(code: "472915", phone: testDevice))
        #expect(requests[1].httpMethod == "GET")
        #expect(requests[1].url?.path() == "/v1/pairing/claim/c1")
        #expect(requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer msb1.claim.p.secret", "polled with the claim's own secret")
    }

    @Test func aWrongCodeIsRejected() async throws {
        let http = FakeHTTP([.failure(.pairingCodeInvalid, status: 404)])
        let store = InMemoryCredentialStore()
        await #expect(throws: TransportError.pairingRejected) {
            _ = try await transport(http, store: store).pair(code: try #require(PairingCode("000001"))) { _ in }
        }
        #expect(store.load() == nil)
        #expect(await http.requests.count == 1, "no polling for a code that was never accepted")
    }

    @Test func anUnknownErrorCodeFromClaimIsARejection() async throws {
        let http = FakeHTTP([.failure("unknown_or_expired_code", status: 404)])
        await #expect(throws: TransportError.pairingRejected) {
            _ = try await transport(http, store: InMemoryCredentialStore()).pair(code: try #require(PairingCode("000001"))) { _ in }
        }
    }

    @Test func tooManyAttemptsIsReported() async throws {
        let http = FakeHTTP([.failure(.rateLimited, status: 429, retryAfter: 60)])
        await #expect(throws: TransportError.rateLimited(retryAfter: 60)) {
            _ = try await transport(http, store: InMemoryCredentialStore()).pair(code: try #require(PairingCode("123456"))) { _ in }
        }
    }

    @Test func theMacSayingNoStoresNothing() async throws {
        let http = FakeHTTP([.json(claim, status: 202), .json(PairingClaimStatus(status: .denied))])
        let store = InMemoryCredentialStore()
        await #expect(throws: TransportError.pairingDenied) {
            _ = try await transport(http, store: store).pair(code: try #require(PairingCode("472915"))) { _ in }
        }
        #expect(store.load() == nil)
    }

    @Test func aClaimTheRelayHasForgottenHasExpired() async throws {
        let http = FakeHTTP([.json(claim, status: 202), .failure(.claimExpired, status: 410)])
        await #expect(throws: TransportError.pairingExpired) {
            _ = try await transport(http, store: InMemoryCredentialStore()).pair(code: try #require(PairingCode("472915"))) { _ in }
        }
    }

    @Test func waitingStopsWhenTheCodeExpires() async throws {
        let http = FakeHTTP([.json(claim, status: 202), .json(PairingClaimStatus(status: .pending))])
        await #expect(throws: TransportError.pairingExpired) {
            _ = try await transport(http, store: InMemoryCredentialStore(), now: Date(timeIntervalSince1970: 2_001)).pair(code: try #require(PairingCode("472915"))) { _ in }
        }
        #expect(await http.requests.count == 1)
    }

    @Test func aBriefDropWhileWaitingIsRetried() async throws {
        let http = FakeHTTP([.json(claim, status: 202), .network(.networkConnectionLost), approved])
        let store = InMemoryCredentialStore()
        _ = try await transport(http, store: store).pair(code: try #require(PairingCode("472915"))) { _ in }
        #expect(store.load()?.token == "tok")
    }

    @Test func cancellingStopsWaiting() async throws {
        let http = FakeHTTP([.json(claim, status: 202), .json(PairingClaimStatus(status: .pending))])
        let store = InMemoryCredentialStore()
        await #expect(throws: CancellationError.self) {
            _ = try await transport(http, store: store, sleeper: RecordingSleeper(stopAfter: 1)).pair(code: try #require(PairingCode("472915"))) { _ in }
        }
        #expect(store.load() == nil)
        #expect(await http.requests.count == 1)
    }

    @Test func anApprovalWithoutATokenIsNotAPairing() async throws {
        let http = FakeHTTP([.json(claim, status: 202), .json(PairingClaimStatus(status: .approved))])
        let store = InMemoryCredentialStore()
        await #expect(throws: TransportError.malformedResponse) {
            _ = try await transport(http, store: store).pair(code: try #require(PairingCode("472915"))) { _ in }
        }
        #expect(store.load() == nil)
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
        #expect(requests[0].httpMethod == "PUT")
        #expect(requests[0].url?.path() == "/v1/tokens/start")
        #expect(try bodyOf(requests[0], as: PushToStartTokenRegistration.self) == PushToStartTokenRegistration(token: "aa"))
        #expect(requests[1].httpMethod == "PUT")
        #expect(requests[1].url?.path() == "/v1/tokens/session")
        #expect(try bodyOf(requests[1], as: SessionPushTokenRegistration.self) == SessionPushTokenRegistration(sessionID: "s/1", token: "bb"))
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

    @Test func aTokenForASessionTheRelayHasEndedIsDropped() async throws {
        let http = FakeHTTP([.network(.notConnectedToInternet)])
        let registrar = RelayPushTokenRegistrar(container: container(), client: { client(http) })
        try? await registrar.registerUpdateToken("bb", forSessionID: "old")
        await http.script([.failure(.sessionMismatch, status: 409)])
        try await registrar.uploadStored()
        #expect(registrar.current().sessions.isEmpty)
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
        case .connection(.macOffline(let name)): "offline:\(name)"
        case .connection(.reconnecting): "reconnecting"
        case .connection(.failed): "failed"
        case .playback(let message): "playback:\(message.revision)"
        case .sessionAssigned(let id): "assigned:\(id)"
        case .sessionEnded(let reason): "ended:\(reason.rawValue)"
        }
    }

    private let live = FakeHTTP.Reply.json(sessionState("s1"))

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
        let http = FakeHTTP([live, live, .json(sessionState("s1", revision: 43))])
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
        let http = FakeHTTP([live, .json(sessionState(nil))])
        let transport = make(http, sleeper: RecordingSleeper(stopAfter: 2))
        let stream = await transport.subscribe()
        await transport.connect()
        let events = await collect(stream, count: 6)
        #expect(events.last == "ended:playbackEnded")
    }

    @Test func noSessionFromTheStartIsNotAnEnding() async {
        let http = FakeHTTP([.json(sessionState(nil))])
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
        #expect(request.url?.path() == "/v1/artwork/p1/\(id)", "the bearer form names the pairing (API-v1 §8)")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")
    }

    @Test func aSignedArtworkURLOnTheRelayIsFetched() async throws {
        let image = encodedImage(.png)
        let http = FakeHTTP([FakeHTTP.Reply(status: 200, body: image, headers: ["Content-Type": "image/png"])])
        let url = URL(string: "https://relay.example.com/v1/artwork/p1/\(String(repeating: "c", count: 64))?sig=abc")!
        #expect(try await client(http).fetch(url: url) == image)
        #expect(await http.requests.first?.url == url, "the signature is kept")
    }

    @Test func refusedArtworkIsMissingArtworkNotARevokedPairing() async throws {
        let http = FakeHTTP([.failure(.unauthorized, status: 401)])
        let store = InMemoryCredentialStore(testCredential)
        let transport = make(http, sleeper: RecordingSleeper(stopAfter: 1), store: store)
        await #expect(throws: TransportError.artworkUnavailable) {
            _ = try await transport.artwork(id: String(repeating: "b", count: 64))
        }
        #expect(store.load() == testCredential)
    }

    @Test func theRelayReachableWithoutTheMacIsReportedAsSuch() async {
        let http = FakeHTTP([.json(sessionState("s1", macConnected: false))])
        let transport = make(http, sleeper: RecordingSleeper(stopAfter: 1))
        let stream = await transport.subscribe()
        await transport.connect()
        let events = await collect(stream, count: 5)
        #expect(events == ["disconnected", "connecting", "offline:Studio Mac", "assigned:s1", "playback:42"])
    }

    @Test func anEndedSessionIsNotReplayedToALaterConsumer() async {
        let http = FakeHTTP([live, .json(sessionState(nil))])
        let transport = make(http, sleeper: RecordingSleeper(stopAfter: 2))
        let first = await transport.subscribe()
        await transport.connect()
        _ = await collect(first, count: 6)
        let second = await transport.subscribe()
        await transport.disconnect()
        #expect(await collect(second, count: 2) == ["connected:Studio Mac", "disconnected"])
    }

    @Test func aCommandCarriesTheRelaysSessionAndIsFollowedByARead() async throws {
        let command = RemoteCommand(kind: .next)
        let http = FakeHTTP([live, .json(CommandResponse(ack: .accepted(command.id, revision: 42))), .json(sessionState("s1", revision: 43))])
        let transport = RelayTransport(configuration: relayConfiguration, credentials: InMemoryCredentialStore(testCredential), http: http, device: { testDevice },
                                       sleep: { seconds in
                                           // Polls wait for the test to end; the read after a command doesn't.
                                           if seconds == 5 { try await Task.sleep(for: .seconds(3600)) }
                                       }, jitter: { 0 })
        let stream = await transport.subscribe()
        await transport.connect()
        _ = await collect(stream, count: 5)
        let ack = try await transport.send(command)
        #expect(ack.accepted)
        #expect(await collect(stream, count: 1) == ["playback:43"])
        await transport.disconnect()

        let sent = await http.requests[1]
        #expect(sent.url?.path() == "/v1/commands")
        #expect(try bodyOf(sent, as: CommandRequest.self).sessionID == "s1")
    }

    @Test func noSessionMeansNoCommand() async throws {
        let http = FakeHTTP([.json(sessionState(nil))])
        let transport = make(http, sleeper: RecordingSleeper(stopAfter: 1))
        await #expect(throws: TransportError.commandRejected(.noSession)) {
            _ = try await transport.send(RemoteCommand(kind: .play))
        }
        #expect(await http.requests.isEmpty)
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

@MainActor
@Suite struct RelaySessionNamingTests {
    @Test func nothingIsShownUntilTheRelayNamesTheSession() async {
        let h = Harness(relayNamesSessions: true)
        let task = await h.run()
        defer { task.cancel() }
        await h.connected()
        await h.transport.emit(.playback(message(revision: 1)))
        await h.transport.emit(.connection(.connected(macName: "Studio Mac")))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.controller.activations.isEmpty, "a made-up session name would get every command refused")
        #expect(h.model.attributes == nil)

        await h.transport.emit(.sessionAssigned("relay-1"))
        await h.transport.emit(.playback(message(revision: 2)))
        await eventually("active") { h.controller.isActive }
        #expect(h.controller.sessionID == "relay-1")
    }

    @Test func theMacGoingOfflineLeavesTheSessionToTheRelay() async {
        let h = Harness()
        let task = await h.run()
        defer { task.cancel() }
        await h.connected()
        await h.play()
        await h.transport.emit(.connection(.macOffline(macName: "Studio Mac")))
        await eventually("offline") { h.model.connection == .macOffline(macName: "Studio Mac") }
        h.clock.advance(120)
        await h.model.sceneDidBecomeActive()
        #expect(h.controller.isActive, "the relay ends it after its own grace period, and says so")
        #expect(h.sleeper.pending == 0, "no local countdown")
    }

    @Test func pairingSaysWhoItIsWaitingFor() async throws {
        let h = Harness(paired: false)
        try await h.model.pair(rawCode: "472915")
        #expect(h.model.log.contains { $0.message == "Waiting for Studio Mac to allow this iPhone" })
        #expect(h.model.pairingAwaitingMac == nil, "cleared once pairing finishes")
        #expect(h.model.pairedMac?.name == "Studio Mac")
    }
}

@Suite struct EmptyArtworkTests {
    @Test func anEmptyArtworkIDMeansNoArtwork() throws {
        let fromPush = try StandByWire.makeDecoder().decode(SessionTrack.self, from: Data(#"{"id":"t","title":"T","artist":"A","album":"B","duration":1,"artworkID":""}"#.utf8))
        #expect(fromPush.artworkReference == nil)
        let absent = SessionTrack(id: "t", title: "T", artist: "A", album: "B", duration: 1, artworkID: nil)
        #expect(absent.artworkReference == nil)
        let real = String(repeating: "a", count: 64)
        #expect(SessionTrack(id: "t", title: "T", artist: "A", album: "B", duration: 1, artworkID: real).artworkReference == real)
    }

    @Test func theMacSendingAnEmptyIDIsNotArtwork() {
        let attributes = MacPlaybackAttributes(mac: studioMac, message: message(track: track(artworkID: "")), sessionID: "s1")
        #expect(attributes.track?.artworkID == nil)
    }
}
