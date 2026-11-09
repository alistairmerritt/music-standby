import Foundation

public enum ConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected(macName: String)
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
        case .notConnected: "Your Mac isn’t connected."
        case .artworkUnavailable: "Artwork isn’t available."
        case .notPaired: "This iPhone isn’t paired with a Mac."
        case .rateLimited: "Too many attempts. Try again shortly."
        case .pairingRevoked: "This pairing has ended. Pair with your Mac again."
        case .commandRejected(let code): "Your Mac refused that command (\(code.rawValue))."
        case .macUnreachable: "Your Mac didn’t respond."
        case .network(let detail): "Network problem: \(detail)"
        case .timedOut: "The relay took too long to answer."
        case .httpStatus(let status): "The relay returned HTTP \(status)."
        case .malformedResponse: "The relay sent an unexpected response."
        }
    }
}

/// How the app talks to a Mac.
public protocol PlaybackTransport: Sendable {
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
    func pair(code: PairingCode) async throws -> PairedMac
    func unpair() async
    func send(_ command: RemoteCommand) async throws -> CommandAck
    func artwork(id: String) async throws -> Data
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
        case .connected, .reconnecting: true
        case .disconnected, .connecting, .failed: false
        }
    }
}
