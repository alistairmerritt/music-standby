import Foundation
import StandByProtocol

/// The Mac's WebSocket to the relay (docs/relay/API-v1.md §5).
///
/// Connects with the Mac's bearer token, says `hello` on every connection, and
/// reconnects after any drop with exponential backoff from 1 s to 30 s, ±20 %
/// jitter, reset after a connection that lasted a minute. It gives up only when
/// the relay refuses the credential, revokes the pairing, or another connection
/// for the same pairing replaces this one. Pings every 30 s; a pong missing for
/// 10 s counts as a drop. Resending state after a reconnect is `Companion`'s
/// job: it does so on every `welcome`.
public actor RelayTransport: CompanionTransport {
    public nonisolated let inbound: AsyncStream<RelayFrame>
    public nonisolated let statusUpdates: AsyncStream<ConnectionStatus>
    private let inboundContinuation: AsyncStream<RelayFrame>.Continuation
    private let statusContinuation: AsyncStream<ConnectionStatus>.Continuation

    public let client: RelayClient
    private let token: @Sendable () -> String?
    private let session: URLSession

    private var hello: Hello?
    private var wanted = false
    private var socket: URLSessionWebSocketTask?
    private var isOpen = false
    private var runner: Task<Void, Never>?
    private var failures = 0

    public var pingInterval: Duration = .seconds(30)
    public var pongDeadline: Duration = .seconds(10)

    public init(client: RelayClient, token: @escaping @Sendable () -> String?) {
        (inbound, inboundContinuation) = AsyncStream.makeStream(of: RelayFrame.self, bufferingPolicy: .unbounded)
        (statusUpdates, statusContinuation) = AsyncStream.makeStream(of: ConnectionStatus.self, bufferingPolicy: .bufferingNewest(16))
        self.client = client
        self.token = token
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        session = URLSession(configuration: configuration)
    }

    // MARK: CompanionTransport

    public func connect(hello: Hello) async {
        self.hello = hello
        wanted = true
        if runner == nil { runner = Task { await self.run() } }
    }

    public func disconnect() async {
        wanted = false
        runner?.cancel()
        runner = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        isOpen = false
        statusContinuation.yield(.disconnected)
    }

    public func send(_ frame: MacFrame) async throws {
        guard isOpen, let socket else { throw ProtocolError(.notConnected) }
        try await socket.send(.string(String(decoding: try frame.encoded(), as: UTF8.self)))
    }

    public func uploadArtwork(_ image: Data, descriptor: ArtworkDescriptor) async throws {
        guard let token = token() else { throw ProtocolError(.notConnected, message: "not registered with the relay") }
        _ = try await client.uploadArtwork(image, descriptor: descriptor, macToken: token)
    }

    // MARK: Connection loop

    private func run() async {
        defer { runner = nil }   // so a later connect() can start again
        while wanted, !Task.isCancelled {
            guard let token = token() else {
                // Not registered yet; RelayAccount is creating the pairing.
                statusContinuation.yield(ConnectionStatus(phase: .connecting, peerName: client.host))
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            let started = Date()
            let outcome = await runOnce(token: token)
            isOpen = false
            socket = nil
            guard wanted, !Task.isCancelled else { return }   // disconnect() was called
            switch outcome {
            case .stop(let error):
                wanted = false
                statusContinuation.yield(.failed(error))
                return
            case .retry(let error):
                if Date().timeIntervalSince(started) > 60 { failures = 0 }
                failures += 1
                let base = min(30.0, pow(2.0, Double(failures - 1)))
                let delay = base * Double.random(in: 0.8...1.2)
                statusContinuation.yield(.reconnecting(at: Date().addingTimeInterval(delay), after: error))
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    private enum Outcome {
        case retry(ProtocolError)
        case stop(ProtocolError)
    }

    private func runOnce(token: String) async -> Outcome {
        statusContinuation.yield(ConnectionStatus(phase: .connecting, peerName: client.host))
        var request = URLRequest(url: client.socketURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let socket = session.webSocketTask(with: request)
        self.socket = socket
        socket.resume()

        var pinger: Task<Void, Never>?
        defer { pinger?.cancel() }
        do {
            guard let hello else { return .stop(ProtocolError(.internal, message: "no hello")) }
            try await socket.send(.string(String(decoding: try MacFrame.hello(hello).encoded(), as: UTF8.self)))
            var welcomed = false
            while true {
                let frame = try await receive(socket)
                if !welcomed, case .welcome = frame {
                    welcomed = true
                    isOpen = true
                    failures = 0
                    statusContinuation.yield(.connected(to: client.host, since: Date()))
                    pinger = Task { await self.keepAlive(socket) }
                }
                inboundContinuation.yield(frame)
                if case .revoked(let reason) = frame {
                    socket.cancel(with: .normalClosure, reason: nil)
                    return .stop(ProtocolError(.pairingRevoked, message: reason))
                }
                if case .error(let error) = frame, error.code == .unsupportedProtocolVersion {
                    return .stop(error)
                }
            }
        } catch {
            let status = (socket.response as? HTTPURLResponse)?.statusCode
            let close = socket.closeCode.rawValue
            if status == 401 { return .stop(ProtocolError(.unauthorized, message: "the relay refused this Mac's credential")) }
            if close == 4410 { return .stop(ProtocolError(.pairingRevoked)) }
            if close == 4409 { return .stop(ProtocolError(.notConnected, message: "another connection for this Mac replaced this one")) }
            socket.cancel(with: .goingAway, reason: nil)
            return .retry(ProtocolError(.notConnected, message: describe(error, status: status, close: close)))
        }
    }

    private func receive(_ socket: URLSessionWebSocketTask) async throws -> RelayFrame {
        switch try await socket.receive() {
        case .string(let text): return try RelayFrame.decode(Data(text.utf8))
        case .data(let data): return try RelayFrame.decode(data)
        @unknown default: throw ProtocolError(.invalidFrame)
        }
    }

    /// A ping every `pingInterval`; no pong within `pongDeadline` drops the socket.
    private func keepAlive(_ socket: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: pingInterval)
            guard !Task.isCancelled else { return }
            let answered = await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    await withCheckedContinuation { continuation in
                        socket.sendPing { error in continuation.resume(returning: error == nil) }
                    }
                }
                group.addTask { [pongDeadline] in
                    try? await Task.sleep(for: pongDeadline)
                    return false
                }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
            if !answered {
                socket.cancel(with: .goingAway, reason: nil)
                return
            }
        }
    }

    private func describe(_ error: Error, status: Int?, close: Int) -> String {
        var parts = [(error as NSError).localizedDescription]
        if let status { parts.append("HTTP \(status)") }
        if close != 0 { parts.append("close \(close)") }
        return parts.joined(separator: ", ")
    }
}
