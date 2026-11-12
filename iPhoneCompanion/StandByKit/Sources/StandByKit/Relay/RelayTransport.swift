import Foundation

/// The app's view of the Mac, by way of the relay.
///
/// Only meaningful while the app is in the foreground. A suspended app is
/// updated by APNs, which the system delivers to the extension. So this reads
/// the relay's current session, retries with backoff when the network fails,
/// and treats a rejected token as the end of the pairing.
public actor RelayTransport: PlaybackTransport {
    public struct Timing: Equatable, Sendable {
        public var pollInterval: TimeInterval
        /// API-v1 §4 asks for a claim poll every 2 s.
        public var claimPollInterval: TimeInterval
        /// The Mac acknowledges before it re-reads Music, so the result of a
        /// command arrives a little after the ack. Nil disables the extra read.
        public var refreshAfterCommand: TimeInterval?
        public var initialBackoff: TimeInterval
        public var maximumBackoff: TimeInterval

        public init(pollInterval: TimeInterval = 5, claimPollInterval: TimeInterval = 2, refreshAfterCommand: TimeInterval? = 0.7, initialBackoff: TimeInterval = 1, maximumBackoff: TimeInterval = 30) {
            self.pollInterval = pollInterval
            self.claimPollInterval = claimPollInterval
            self.refreshAfterCommand = refreshAfterCommand
            self.initialBackoff = initialBackoff
            self.maximumBackoff = maximumBackoff
        }

        /// Exponential from `initialBackoff`, capped. `jitter` is 0...1 and only
        /// ever lengthens the wait.
        public func backoff(afterFailures failures: Int, jitter: Double) -> TimeInterval {
            let exponent = min(max(failures - 1, 0), 16)
            let base = min(initialBackoff * pow(2, Double(exponent)), maximumBackoff)
            return min(base * (1 + 0.25 * jitter), maximumBackoff)
        }
    }

    private var hub = TransportEventHub()
    private var loop: Task<Void, Never>?
    private let configuration: RelayConfiguration
    private let credentials: any CredentialStore
    private let http: any HTTPSending
    private let device: @Sendable () -> DeviceIdentity
    private let timing: Timing
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let jitter: @Sendable () -> Double

    public nonisolated var issuesSessionIDs: Bool { true }

    public init(
        configuration: RelayConfiguration,
        credentials: any CredentialStore,
        http: any HTTPSending,
        device: @escaping @Sendable () -> DeviceIdentity,
        timing: Timing = Timing(),
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }
    ) {
        self.configuration = configuration
        self.credentials = credentials
        self.http = http
        self.device = device
        self.timing = timing
        self.now = now
        self.sleep = sleep
        self.jitter = jitter
    }

    public func subscribe() -> AsyncStream<TransportEvent> {
        hub.subscribe()
    }

    public func connect() async {
        guard loop == nil else { return }
        startLoop()
    }

    public func reconnect() async {
        loop?.cancel()
        startLoop()
    }

    public func disconnect() async {
        loop?.cancel()
        loop = nil
        hub.send(.connection(.disconnected))
    }

    /// A suspended app's requests fail, which would read as a lost connection.
    /// Stop asking instead, and say nothing: the session is the relay's to end.
    public func suspend() async {
        loop?.cancel()
        loop = nil
    }

    /// Claims the code, then waits for the person at the Mac (API-v1 §4).
    /// Cancelling the task stops waiting; the relay lets the claim expire.
    public func pair(code: PairingCode, progress: @escaping @Sendable (PairingProgress) async -> Void) async throws -> PairedMac {
        let client = RelayClient(configuration: configuration, http: http, token: { nil })
        let claim = try await client.claimPairing(code: code, device: device())
        await progress(.waitingForApproval(claim.mac))
        while true {
            guard now() < claim.expiresAt else { throw TransportError.pairingExpired }
            try await sleep(timing.claimPollInterval)
            try Task.checkCancellation()
            let status: PairingClaimStatus
            do {
                status = try await client.claimStatus(claim)
            } catch let error as TransportError where error.isTransient {
                continue
            }
            switch status.status {
            case .pending:
                continue
            case .denied:
                throw TransportError.pairingDenied
            case .approved:
                guard let pairingID = status.pairingID, let token = status.phoneToken else { throw TransportError.malformedResponse }
                let mac = status.mac ?? claim.mac
                try credentials.save(RelayCredential(configuration: configuration, pairingID: pairingID, token: token, mac: mac))
                return mac
            }
        }
    }

    public func unpair() async {
        if let client = try? makeClient() {
            try? await client.deletePairing()
        }
        try? credentials.delete()
        await disconnect()
        hub.reset()
    }

    /// Sends under the session the relay named. Without one there is nothing
    /// for a command to act on.
    public func send(_ command: RemoteCommand) async throws -> CommandAck {
        guard let sessionID = hub.assignedSession else { throw TransportError.commandRejected(.noSession) }
        let ack = try await makeClient().send(command, sessionID: sessionID)
        if ack.accepted { scheduleRefresh() }
        return ack
    }

    public func artwork(id: String) async throws -> Data {
        try await makeClient().fetch(id: id)
    }

    private func makeClient() throws -> RelayClient {
        guard let credential = try credentials.load() else { throw TransportError.notPaired }
        return RelayClient(credential: credential, http: http)
    }

    private func startLoop() {
        loop = Task { [weak self] in
            await self?.run()
        }
    }

    private func run() async {
        guard let credential = try? credentials.load() else {
            setConnection(.failed(TransportError.notPaired.localizedDescription))
            loop = nil
            return
        }
        let client = RelayClient(credential: credential, http: http)
        setConnection(.connecting)
        var failures = 0
        while !Task.isCancelled {
            do {
                let state = try await client.fetchSession()
                guard !Task.isCancelled else { return }
                failures = 0
                apply(state)
                try await sleep(timing.pollInterval)
            } catch TransportError.pairingRevoked {
                pairingWasRevoked()
                return
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                failures += 1
                setConnection(.reconnecting)
                do {
                    try await sleep(timing.backoff(afterFailures: failures, jitter: jitter()))
                } catch {
                    return
                }
            }
        }
    }

    /// One extra read soon after a command, so the app shows its result
    /// without waiting for the next poll. Foreground only, like the loop.
    private func scheduleRefresh() {
        guard loop != nil, let delay = timing.refreshAfterCommand, let client = try? makeClient() else { return }
        Task { [weak self, sleep] in
            do { try await sleep(delay) } catch { return }
            guard let state = try? await client.fetchSession() else { return }
            await self?.applyIfRunning(state)
        }
    }

    public func refreshState() async {
        guard loop != nil, let client = try? makeClient(), let state = try? await client.fetchSession() else { return }
        applyIfRunning(state)
    }

    private func applyIfRunning(_ state: SessionState) {
        guard loop != nil else { return }
        apply(state)
    }

    /// The relay is the authority: its session, or none, is the truth.
    private func apply(_ state: SessionState) {
        let name = state.mac.name
        setConnection(state.macConnected ? .connected(macName: name) : .macOffline(macName: name))
        guard let sessionID = state.sessionID, let playback = state.playback else {
            if hub.assignedSession != nil { hub.send(.sessionEnded(.playbackEnded)) }
            // Nothing to replay to a later subscriber without a session.
            hub.reset()
            return
        }
        if hub.assignedSession != sessionID { hub.send(.sessionAssigned(sessionID)) }
        if hub.latestPlayback != playback { hub.send(.playback(playback)) }
    }

    private func pairingWasRevoked() {
        try? credentials.delete()
        setConnection(.failed(TransportError.pairingRevoked.localizedDescription))
        hub.send(.sessionEnded(.pairingRevoked))
        hub.reset()
        loop = nil
    }

    private func setConnection(_ state: ConnectionState) {
        guard hub.connection != state else { return }
        hub.send(.connection(state))
    }
}

extension TransportError {
    /// Worth trying again shortly: the network, a busy relay or a server fault.
    var isTransient: Bool {
        switch self {
        case .network, .timedOut, .rateLimited, .macUnreachable: true
        case .httpStatus(let status): status >= 500
        default: false
        }
    }
}

extension RelayClient {
    public init(credential: RelayCredential, http: any HTTPSending, artworkPolicy: ArtworkPolicy = ArtworkPolicy()) {
        let token = credential.token
        self.init(configuration: credential.configuration, http: http, artworkPolicy: artworkPolicy, pairingID: credential.pairingID, token: { token })
    }
}

/// A transport for a build with no relay to talk to. Reports that and does nothing.
public actor UnconfiguredTransport: PlaybackTransport {
    private var hub = TransportEventHub()
    public init() {}
    public func subscribe() -> AsyncStream<TransportEvent> { hub.subscribe() }
    public func connect() { hub.send(.connection(.failed("No relay is configured."))) }
    public func reconnect() { connect() }
    public func disconnect() { hub.send(.connection(.disconnected)) }
    public func pair(code: PairingCode, progress: @escaping @Sendable (PairingProgress) async -> Void) throws -> PairedMac { throw TransportError.notConnected }
    public func unpair() {}
    public func send(_ command: RemoteCommand) throws -> CommandAck { throw TransportError.notConnected }
    public func artwork(id: String) throws -> Data { throw TransportError.artworkUnavailable }
}
