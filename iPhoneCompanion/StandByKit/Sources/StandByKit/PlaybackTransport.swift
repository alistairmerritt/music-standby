import Foundation

public enum ConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected(macName: String)
    case failed(String)
}

public enum TransportEvent: Sendable {
    case connection(ConnectionState)
    case playback(PlaybackMessage)
}

public enum TransportError: Error, Equatable, Sendable, LocalizedError {
    case pairingRejected
    case notConnected
    case artworkUnavailable

    public var errorDescription: String? {
        switch self {
        case .pairingRejected: "That code wasn’t accepted. Check the code shown on your Mac."
        case .notConnected: "Your Mac isn’t connected."
        case .artworkUnavailable: "Artwork isn’t available."
        }
    }
}

/// How the app talks to a Mac. `MockTransport` implements it today; the real
/// transport replaces it once the shared protocol is published.
public protocol PlaybackTransport: Sendable {
    var events: AsyncStream<TransportEvent> { get }
    func connect() async
    func disconnect() async
    func pair(code: PairingCode) async throws -> PairedMac
    func send(_ command: RemoteCommand) async throws -> CommandAck
    func artwork(id: String) async throws -> Data
}
