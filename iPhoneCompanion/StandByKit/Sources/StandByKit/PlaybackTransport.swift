import Foundation

public enum ConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected(macName: String)
    /// The relay answers but the Mac isn't connected to it. The relay decides
    /// when that ends the session, and says so.
    case macOffline(macName: String)
    /// The link dropped and the transport is retrying. Temporary: a session
    /// survives this for the grace period in `SessionLifecyclePolicy`.
    case reconnecting
    case failed(String)
}

/// Why a Now Playing session was ended. Recorded for diagnostics.
public enum SessionEndReason: String, Equatable, Sendable {
    /// The Mac confirmed playback finished: stopped, Music quit, or Automation refused.
    case playbackEnded
    case userStopped
    case unpaired
    /// The transport was disconnected on purpose.
    case macDisconnected
    /// The link stayed down past the grace period.
    case connectionLost
    case pairingRevoked
    /// The relay issued a different session identifier.
    case replaced
}

public enum TransportEvent: Sendable {
    case connection(ConnectionState)
    case playback(PlaybackMessage)
    /// The session identifier to publish under, when the relay issues one.
    case sessionAssigned(String)
    /// The far side says the session is over.
    case sessionEnded(SessionEndReason)
}

public enum TransportError: Error, Equatable, Sendable, LocalizedError {
    case pairingRejected
    /// The person at the Mac refused this phone.
    case pairingDenied
    /// The code or the wait for the Mac ran out.
    case pairingExpired
    case notConnected
    case artworkUnavailable
    case notPaired
    case rateLimited(retryAfter: TimeInterval?)
    case pairingRevoked
    case commandRejected(ErrorCode)
    case macUnreachable
    case network(String)
    case timedOut
    case httpStatus(Int)
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .pairingRejected: "That code wasn’t accepted. Check the code shown on your Mac."
        case .pairingDenied: "Your Mac didn’t allow this iPhone."
        case .pairingExpired: "The code expired before your Mac allowed this iPhone. Get a new code and try again."
        case .notConnected: "Your Mac isn’t connected."
        case .artworkUnavailable: "Artwork isn’t available."
        case .notPaired: "This iPhone isn’t paired with a Mac."
        case .rateLimited: "Too many attempts. Try again shortly."
        case .pairingRevoked: "This pairing has ended. Pair with your Mac again."
        case .commandRejected(.sessionMismatch), .commandRejected(.noSession): "That session has ended on your Mac."
        case .commandRejected(let code): "Your Mac refused that command (\(code.rawValue))."
        case .macUnreachable: "Your Mac didn’t respond."
        case .network(let detail): "Network problem: \(detail)"
        case .timedOut: "The relay took too long to answer."
        case .httpStatus(let status): "The relay returned HTTP \(status)."
        case .malformedResponse: "The relay sent an unexpected response."
        }
    }
}

/// What pairing is waiting for, so the screen can say so.
public enum PairingProgress: Equatable, Sendable {
    /// The code was accepted. Nothing is granted until the person at this Mac allows it.
    case waitingForApproval(PairedMac)
}

/// How the app talks to a Mac.
public protocol PlaybackTransport: Sendable {
    /// True when the far side names each Now Playing session, as the relay does.
    /// The app then shows nothing until it has a name, and sends it with commands.
    var issuesSessionIDs: Bool { get }
    /// A fresh event stream. It finishes any earlier stream and starts with the
    /// transport's current state, so a consumer that was cancelled can restart
    /// without missing where things stand.
    func subscribe() async -> AsyncStream<TransportEvent>
    /// Safe to call when already connected.
    func connect() async
    /// Re-establishes the link without reporting a deliberate disconnection,
    /// so a Now Playing session survives it.
    func reconnect() async
    func disconnect() async
    /// Stops talking to the far side without reporting a disconnection, for an
    /// app leaving the foreground. `connect()` picks up again.
    func suspend() async
    /// Returns once the pairing is complete. `progress` hears about any wait.
    func pair(code: PairingCode, progress: @escaping @Sendable (PairingProgress) async -> Void) async throws -> PairedMac
    func unpair() async
    func send(_ command: RemoteCommand) async throws -> CommandAck
    func artwork(id: String) async throws -> Data
    /// Reads the Mac's state now rather than at the next poll. Send back to
    /// Mac uses it to see the Mac playing without waiting 5 s.
    func refreshState() async
}

extension PlaybackTransport {
    public var issuesSessionIDs: Bool { false }
    public func suspend() async {}
}

/// Delivers events to the current subscriber and remembers enough to bring a
/// new one up to date. Lives inside a transport actor.
public struct TransportEventHub: Sendable {
    private var continuation: AsyncStream<TransportEvent>.Continuation?
    public private(set) var connection: ConnectionState = .disconnected
    public private(set) var latestPlayback: PlaybackMessage?
    public private(set) var assignedSession: String?

    public init() {}

    public mutating func subscribe() -> AsyncStream<TransportEvent> {
        continuation?.finish()
        let (stream, newContinuation) = AsyncStream.makeStream(of: TransportEvent.self, bufferingPolicy: .bufferingNewest(32))
        continuation = newContinuation
        newContinuation.yield(.connection(connection))
        if isLinkUp {
            if let assignedSession { newContinuation.yield(.sessionAssigned(assignedSession)) }
            if let latestPlayback { newContinuation.yield(.playback(latestPlayback)) }
        }
        return stream
    }

    public mutating func send(_ event: TransportEvent) {
        switch event {
        case .connection(let state): connection = state
        case .playback(let message): latestPlayback = message
        case .sessionAssigned(let id): assignedSession = id
        case .sessionEnded: assignedSession = nil
        }
        continuation?.yield(event)
    }

    /// Forgets playback, for an unpair.
    public mutating func reset() {
        latestPlayback = nil
        assignedSession = nil
    }

    private var isLinkUp: Bool {
        switch connection {
        case .connected, .macOffline, .reconnecting: true
        case .disconnected, .connecting, .failed: false
        }
    }
}

extension PlaybackTransport {
    /// Transports that are told everything as it happens have nothing to fetch.
    public func refreshState() async {}
}
