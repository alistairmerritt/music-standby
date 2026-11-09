import Foundation

extension Data {
    public var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

public struct PushTokens: Codable, Equatable, Sendable {
    public var pushToStart: String?
    public var sessions: [String: String] = [:]

    public init(pushToStart: String? = nil, sessions: [String: String] = [:]) {
        self.pushToStart = pushToStart
        self.sessions = sessions
    }
}

/// Where tokens go. A real implementation will send them to the backend over HTTPS.
public protocol PushTokenRegistrar: Sendable {
    func registerStartToken(_ hex: String) async throws
    func registerUpdateToken(_ hex: String, forSessionID id: String) async throws
    /// Apple asks that a session's token be invalidated promptly once it ends.
    func invalidate(sessionID id: String) async throws
    /// What is held locally, for Diagnostics.
    func current() -> PushTokens
}

/// Stores tokens in the shared container so Diagnostics can show them.
public struct MockPushTokenRegistrar: PushTokenRegistrar {
    private let url: URL

    public init(container: SharedContainer) {
        url = container.file("push-tokens.json")
    }

    public func current() -> PushTokens {
        guard let data = try? Data(contentsOf: url) else { return PushTokens() }
        return (try? JSONDecoder().decode(PushTokens.self, from: data)) ?? PushTokens()
    }

    public func registerStartToken(_ hex: String) async throws {
        var tokens = current()
        tokens.pushToStart = hex
        try JSONEncoder().encode(tokens).write(to: url, options: .atomic)
    }

    public func registerUpdateToken(_ hex: String, forSessionID id: String) async throws {
        var tokens = current()
        tokens.sessions[id] = hex
        try JSONEncoder().encode(tokens).write(to: url, options: .atomic)
    }

    public func invalidate(sessionID id: String) async throws {
        var tokens = current()
        tokens.sessions[id] = nil
        try JSONEncoder().encode(tokens).write(to: url, options: .atomic)
    }
}
