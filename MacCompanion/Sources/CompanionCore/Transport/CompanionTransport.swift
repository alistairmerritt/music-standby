import Foundation
import StandByProtocol

/// How the companion reaches the relay. Speaks `StandByProtocol` frames only.
///
/// The production transport will be a WebSocket to the relay's Durable
/// Object, with artwork uploaded over HTTPS (relay design §4). Today only
/// `MockRelayTransport` exists. Each stream has a single consumer: `Companion`.
public protocol CompanionTransport: AnyObject, Sendable {
    /// Frames from the relay, in order.
    var inbound: AsyncStream<RelayFrame> { get }
    /// Link state changes, in order.
    var statusUpdates: AsyncStream<ConnectionStatus> { get }

    /// Connects and sends `hello`. Reconnecting after a drop, with backoff, is
    /// the transport's job; it says `hello` again each time.
    func connect(hello: Hello) async
    func disconnect() async
    /// Throws `ProtocolError(.notConnected)` when there is no link.
    func send(_ frame: MacFrame) async throws
    /// `PUT /v1/artwork/{artworkID}` in the relay design.
    func uploadArtwork(_ image: Data, descriptor: ArtworkDescriptor) async throws
}
