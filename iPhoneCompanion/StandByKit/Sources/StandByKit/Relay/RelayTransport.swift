import Foundation

/// The app's view of the Mac, by way of the relay.
///
/// Only meaningful while the app is in the foreground. A suspended app is
/// updated by APNs, which the system delivers to the extension. So this polls
/// the relay's current session, retries with backoff when the network fails,
/// and treats a rejected token as the end of the pairing.
public actor RelayTransport: PlaybackTransport {
    public struct Timing: Equatable, Sendable {
        public var pollInterval: TimeInterval
        public var initialBackoff: TimeInterval
        public var maximumBackoff: TimeInterval

        public init(pollInterval: TimeInterval = 5, initialBackoff: TimeInterval = 1, maximumBackoff: TimeInterval = 30) {
            self.pollInterval = pollInterval
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
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let jitter: @Sendable () -> Double

    public init(
        configuration: RelayConfiguration,
        credentials: any CredentialStore,
        http: any HTTPSending,
        device: @escaping @Sendable () -> DeviceIdentity,
        timing: Timing = Timing(),
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }
    ) {
        self.configuration = configuration
        self.credentials = credentials
        self.http = http
        self.device = device
        self.timing = timing
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

    public func pair(code: PairingCode) async throws -> PairedMac {
        let client = RelayClient(configuration: configuration, http: http, token: { nil })
        let grant = try await client.claimPairing(code: code, device: device())
        try credentials.save(RelayCredential(configuration: configuration, pairingID: grant.pairingID, token: grant.phoneToken, mac: grant.mac))
        return grant.mac
    }

    public func unpair() async {
        if let client = try? makeClient() {
            try? await client.deletePairing()
        }
        try? credentials.delete()
        await disconnect()
        hub.reset()
    }

    public func send(_ command: RemoteCommand) async throws -> CommandAck {
        try await makeClient().send(command)
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
                let session = try await client.fetchSession()
                guard !Task.isCancelled else { return }
                failures = 0
                apply(session, macName: credential.mac.name)
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

    private func apply(_ session: RelaySession?, macName: String) {
        setConnection(.connected(macName: macName))
        guard let session else {
            if hub.assignedSession != nil { hub.send(.sessionEnded(.playbackEnded)) }
            return
        }
        if hub.assignedSession != session.sessionID { hub.send(.sessionAssigned(session.sessionID)) }
        if hub.latestPlayback != session.playback { hub.send(.playback(session.playback)) }
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

extension RelayClient {
    public init(credential: RelayCredential, http: any HTTPSending, artworkPolicy: ArtworkPolicy = ArtworkPolicy()) {
        let token = credential.token
        self.init(configuration: credential.configuration, http: http, artworkPolicy: artworkPolicy, token: { token })
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
    public func pair(code: PairingCode) throws -> PairedMac { throw TransportError.notConnected }
    public func unpair() {}
    public func send(_ command: RemoteCommand) throws -> CommandAck { throw TransportError.notConnected }
    public func artwork(id: String) throws -> Data { throw TransportError.artworkUnavailable }
}
