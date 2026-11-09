import Foundation
import StandByProtocol

/// An in-process stand-in for the relay.
///
/// Everything crosses it as wire JSON: outbound frames are encoded with
/// `StandByWire`, decoded back and compared, and simulated commands are
/// encoded and decoded the same way. So a frame that works here is one the
/// real relay could read. It also behaves like the proposed relay where that
/// matters to the Mac: it says `welcome`, and asks for artwork it hasn't seen.
public actor MockRelayTransport: CompanionTransport {
    public nonisolated let inbound: AsyncStream<RelayFrame>
    public nonisolated let statusUpdates: AsyncStream<ConnectionStatus>
    private let inboundContinuation: AsyncStream<RelayFrame>.Continuation
    private let statusContinuation: AsyncStream<ConnectionStatus>.Continuation

    public static let peerName = "Mock relay"

    /// Every frame sent, decoded back from its JSON.
    public private(set) var sent: [MacFrame] = []
    /// The JSON actually produced, one line per frame.
    public private(set) var sentJSON: [String] = []
    public private(set) var uploads: [String: ArtworkDescriptor] = [:]
    public private(set) var isConnected = false
    public var requestsArtwork: Bool
    private var requested: Set<String> = []
    private let log: (@Sendable (String) -> Void)?

    public init(requestsArtwork: Bool = true, log: (@Sendable (String) -> Void)? = nil) {
        (inbound, inboundContinuation) = AsyncStream.makeStream(of: RelayFrame.self, bufferingPolicy: .unbounded)
        (statusUpdates, statusContinuation) = AsyncStream.makeStream(of: ConnectionStatus.self, bufferingPolicy: .bufferingNewest(16))
        self.requestsArtwork = requestsArtwork
        self.log = log
    }

    // MARK: CompanionTransport

    public func connect(hello: Hello) async {
        statusContinuation.yield(.connecting)
        isConnected = true
        try? await send(.hello(hello))
        statusContinuation.yield(.connected(to: Self.peerName, since: Date()))
        deliver(.welcome(protocolVersion: StandByWire.version))
    }

    public func disconnect() async {
        isConnected = false
        statusContinuation.yield(.disconnected)
    }

    public func send(_ frame: MacFrame) async throws {
        guard isConnected else { throw ProtocolError(.notConnected) }
        let data = try frame.encoded()
        let decoded = try MacFrame.decode(data)
        guard decoded == frame else {
            throw ProtocolError(.invalidFrame, message: "frame changed in a JSON round trip")
        }
        sent.append(decoded)
        let json = String(decoding: data, as: UTF8.self)
        sentJSON.append(json)
        log?("→ \(json)")

        if case .state(let message) = decoded, requestsArtwork, let id = message.track?.artworkID,
           uploads[id] == nil, !requested.contains(id) {
            requested.insert(id)
            deliver(.artworkRequest(artworkID: id))
        }
    }

    public func uploadArtwork(_ image: Data, descriptor: ArtworkDescriptor) async throws {
        guard isConnected else { throw ProtocolError(.notConnected) }
        guard image.count == descriptor.byteCount, image.count <= ArtworkDescriptor.maximumByteCount else {
            throw ProtocolError(.invalidFrame, message: "artwork size mismatch or over the cap")
        }
        uploads[descriptor.artworkID] = descriptor
        log?("⇡ artwork \(descriptor.artworkID) \(descriptor.byteCount) bytes")
    }

    // MARK: Simulating the phone and the relay

    /// A phone command, as the relay would forward it. Returns its id.
    @discardableResult
    public func simulateCommand(_ kind: CommandKind, issuedAt: Date? = Date(), id: UUID = UUID()) -> UUID {
        let frame = RelayFrame.command(RemoteCommand(id: id, kind: kind, issuedAt: issuedAt))
        if let data = try? frame.encoded() { simulateJSON(data) }
        return id
    }

    /// Delivers raw JSON as if it arrived on the socket.
    public func simulateJSON(_ data: Data) {
        do {
            let frame = try RelayFrame.decode(data)
            log?("← \(String(decoding: data, as: UTF8.self))")
            deliver(frame)
        } catch {
            log?("← undecodable frame dropped: \(error)")
        }
    }

    public func simulate(_ frame: RelayFrame) {
        deliver(frame)
    }

    /// The socket drops. The companion should resend state on reconnect.
    public func simulateDrop(retryAt: Date) {
        isConnected = false
        statusContinuation.yield(.reconnecting(at: retryAt, after: ProtocolError(.notConnected, message: "simulated drop")))
    }

    public func simulateStatus(_ status: ConnectionStatus) {
        statusContinuation.yield(status)
    }

    /// The acknowledgement sent for a command, if any.
    public func ack(for commandID: UUID) -> CommandAck? {
        for case .ack(let ack) in sent.reversed() where ack.commandID == commandID { return ack }
        return nil
    }

    private func deliver(_ frame: RelayFrame) {
        inboundContinuation.yield(frame)
    }
}
