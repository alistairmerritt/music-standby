import Foundation
import Network
import Testing
@testable import StandByKit

/// A real TCP server on loopback, so `URLSessionHTTP` is exercised for real.
/// Each connection gets one reply and is closed. A nil reply holds the connection open.
final class LoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "loopback-server")
    private let lock = NSLock()
    private var heads: [String] = []
    private var held: [NWConnection] = []
    private let reply: @Sendable (String) -> Data?

    var requests: [String] { lock.withLock { heads } }

    init(reply: @escaping @Sendable (String) -> Data?) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        self.reply = reply
    }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            let resumed = Once()
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    if resumed.claim() { continuation.resume(returning: listener.port!.rawValue) }
                case .failed(let error):
                    if resumed.claim() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        lock.withLock { held.forEach { $0.cancel() } }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
            guard let self else { return }
            let head = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            self.lock.withLock { self.heads.append(head) }
            guard let response = self.reply(head) else {
                self.lock.withLock { self.held.append(connection) }
                return
            }
            connection.send(content: response, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
}

private func response(status: String = "200 OK", headers: [String] = [], body: Data = Data()) -> Data {
    var head = "HTTP/1.1 \(status)\r\n"
    for header in headers + ["Connection: close"] { head += header + "\r\n" }
    return Data((head + "\r\n").utf8) + body
}

private func relay(_ port: UInt16) -> RelayConfiguration {
    RelayConfiguration(baseURL: URL(string: "http://127.0.0.1:\(port)")!)!
}

@Suite(.serialized) struct URLSessionHTTPTests {
    @Test func aCommandCompletesARealRoundTrip() async throws {
        let command = RemoteCommand(kind: .pause, issuedAt: Date(timeIntervalSince1970: 1_000))
        let body = try StandByWire.makeEncoder().encode(CommandResponse(ack: .accepted(command.id, revision: 9)))
        let server = try LoopbackServer { _ in
            response(headers: ["Content-Type: application/json", "Content-Length: \(body.count)", "X-Protocol-Version: 1"], body: body)
        }
        let port = try await server.start()
        defer { server.stop() }

        let client = RelayClient(configuration: relay(port), http: URLSessionHTTP(), token: { "secret" })
        let ack = try await client.send(command, sessionID: "s1")
        #expect(ack.accepted)
        #expect(ack.revision == 9)

        let head = try #require(server.requests.first)
        #expect(head.hasPrefix("POST /v1/commands HTTP/1.1"))
        #expect(head.lowercased().contains("authorization: bearer secret"))
        #expect(head.lowercased().contains("idempotency-key: \(command.id.uuidString.lowercased())"))
    }

    @Test func aRedirectIsNotFollowedSoTheTokenCantTravel() async throws {
        let server = try LoopbackServer { _ in
            response(status: "302 Found", headers: ["Location: http://127.0.0.1:1/elsewhere", "Content-Length: 0"])
        }
        let port = try await server.start()
        defer { server.stop() }

        let client = RelayClient(configuration: relay(port), http: URLSessionHTTP(), token: { "secret" })
        await #expect(throws: TransportError.httpStatus(302)) {
            _ = try await client.fetchSession()
        }
        #expect(server.requests.count == 1)
    }

    @Test func aRedirectToTheSameServerIsNotFollowedEither() async throws {
        let counter = Counter()
        let server = try LoopbackServer { _ in
            counter.increment()
            return response(status: "307 Temporary Redirect", headers: ["Location: /v1/other", "Content-Length: 0"])
        }
        let port = try await server.start()
        defer { server.stop() }

        await #expect(throws: TransportError.httpStatus(307)) {
            _ = try await RelayClient(configuration: relay(port), http: URLSessionHTTP(), token: { "t" }).fetchSession()
        }
        #expect(counter.value == 1)
    }

    @Test func aDeclaredOversizeResponseIsRefused() async throws {
        let server = try LoopbackServer { _ in response(headers: ["Content-Length: 1000000"], body: Data(repeating: 1, count: 1_000_000)) }
        let port = try await server.start()
        defer { server.stop() }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/a")!)
        request.timeoutInterval = 5
        await #expect(throws: TransportError.artworkUnavailable) {
            _ = try await URLSessionHTTP().send(request, maxBytes: 16)
        }
    }

    @Test func anUndeclaredOversizeResponseIsCutOff() async throws {
        let server = try LoopbackServer { _ in response(body: Data(repeating: 1, count: 4096)) }
        let port = try await server.start()
        defer { server.stop() }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/a")!)
        request.timeoutInterval = 5
        await #expect(throws: TransportError.artworkUnavailable) {
            _ = try await URLSessionHTTP().send(request, maxBytes: 16)
        }
    }

    @Test func aResponseExactlyAtTheLimitIsReturnedWhole() async throws {
        let payload = Data(repeating: 7, count: 16)
        let server = try LoopbackServer { _ in response(headers: ["Content-Length: 16"], body: payload) }
        let port = try await server.start()
        defer { server.stop() }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/a")!)
        request.timeoutInterval = 5
        let (data, http) = try await URLSessionHTTP().send(request, maxBytes: 16)
        #expect(data == payload)
        #expect(http.statusCode == 200)
    }

    @Test func aRelayThatNeverAnswersMeansTheMacIsUnreachable() async throws {
        let server = try LoopbackServer { _ in nil }
        let port = try await server.start()
        defer { server.stop() }

        let client = RelayClient(configuration: relay(port), http: URLSessionHTTP(), token: { "t" })
        let started = Date()
        await #expect(throws: TransportError.macUnreachable) {
            _ = try await client.send(RemoteCommand(kind: .play), sessionID: "s1")
        }
        #expect(Date().timeIntervalSince(started) < 5, "a command must not hang")
    }

    @Test func aRefusedConnectionIsANetworkError() async throws {
        // Bind then release a port so nothing is listening on it.
        let server = try LoopbackServer { _ in nil }
        let port = try await server.start()
        server.stop()

        let client = RelayClient(configuration: relay(port), http: URLSessionHTTP(), token: { "t" })
        await #expect(throws: TransportError.self) {
            _ = try await client.fetchSession()
        }
    }

    @Test func realArtworkIsFetchedAndValidated() async throws {
        let image = encodedImage(.jpeg)
        let server = try LoopbackServer { _ in
            response(headers: ["Content-Type: image/jpeg", "Content-Length: \(image.count)"], body: image)
        }
        let port = try await server.start()
        defer { server.stop() }

        let client = RelayClient(configuration: relay(port), http: URLSessionHTTP(), pairingID: "p1", token: { "t" })
        #expect(try await client.fetch(id: String(repeating: "c", count: 64)) == image)
        let head = try #require(server.requests.first)
        #expect(head.hasPrefix("GET /v1/artwork/p1/\(String(repeating: "c", count: 64)) HTTP/1.1"))
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
