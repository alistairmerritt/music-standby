import Foundation

/// What a tap on a system control does.
public protocol SessionCommandHandling: Sendable {
    /// Returns attributes to show straight away, or nil to wait for the
    /// authoritative update. Throwing tells the system the command failed.
    func perform(_ kind: CommandKind, on attributes: MacPlaybackAttributes, at date: Date) async throws -> MacPlaybackAttributes?
}

/// The production path: straight to the relay from the extension, whether or
/// not the main app is running. Nothing is changed on screen until the Mac's
/// own state arrives, so the phone can't disagree with it.
public struct RelayCommandHandler: SessionCommandHandling {
    private let sender: any CommandSender

    public init(sender: any CommandSender) {
        self.sender = sender
    }

    public func perform(_ kind: CommandKind, on attributes: MacPlaybackAttributes, at date: Date) async throws -> MacPlaybackAttributes? {
        let ack = try await sender.send(RemoteCommand(kind: kind, issuedAt: date))
        guard ack.accepted else { throw TransportError.commandRejected(ack.error?.code ?? .commandFailed) }
        return nil
    }
}

/// Development only: makes the controls respond with no Mac or relay. The sole
/// user of `MockLibrary`'s guess at the next track.
public struct MockCommandHandler: SessionCommandHandling {
    private let library: MockLibrary
    private let log: CommandLog

    public init(library: MockLibrary = .standard, container: SharedContainer) {
        self.library = library
        log = CommandLog(container: container)
    }

    public func perform(_ kind: CommandKind, on attributes: MacPlaybackAttributes, at date: Date) async throws -> MacPlaybackAttributes? {
        // Only bookkeeping for Diagnostics: failing to write it mustn't fail the tap.
        try? log.append(CommandRecord(kind: kind, sessionID: attributes.id, receivedAt: date))
        CrossProcessSignal.post(AppGroup.commandSignal)
        return library.applying(kind, to: attributes, at: date)
    }
}

/// No pairing, so nowhere to send anything.
public struct UnpairedCommandHandler: SessionCommandHandling {
    public init() {}

    public func perform(_ kind: CommandKind, on attributes: MacPlaybackAttributes, at date: Date) async throws -> MacPlaybackAttributes? {
        throw TransportError.notPaired
    }
}

/// Sends tokens to the relay and keeps a local copy for Diagnostics and retries.
///
/// Tokens can appear before pairing or while offline. They stay in the local
/// copy, and `uploadStored()` sends them once it can.
public struct RelayPushTokenRegistrar: PushTokenRegistrar {
    private let local: MockPushTokenRegistrar
    private let client: @Sendable () -> RelayClient?

    public init(container: SharedContainer, client: @escaping @Sendable () -> RelayClient?) {
        local = MockPushTokenRegistrar(container: container)
        self.client = client
    }

    // The local copy is a convenience. If it can't be written, the relay must
    // still hear about the token.

    public func registerStartToken(_ hex: String) async throws {
        try? await local.registerStartToken(hex)
        try await client()?.registerStartToken(hex)
    }

    public func registerUpdateToken(_ hex: String, forSessionID id: String) async throws {
        try? await local.registerUpdateToken(hex, forSessionID: id)
        try await client()?.registerSessionToken(hex, sessionID: id)
    }

    public func invalidate(sessionID id: String) async throws {
        try? await local.invalidate(sessionID: id)
        try await client()?.invalidateSessionToken(sessionID: id)
    }

    public func current() -> PushTokens {
        local.current()
    }

    public func uploadStored() async throws {
        guard let client = client() else { return }
        let tokens = local.current()
        if let start = tokens.pushToStart { try await client.registerStartToken(start) }
        for (id, hex) in tokens.sessions { try await client.registerSessionToken(hex, sessionID: id) }
    }
}

extension PushTokenRegistrar {
    /// Nothing to do for a registrar with no server behind it.
    public func uploadStored() async throws {}
}

public enum BuildFlavor {
    public static var isDebug: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}

/// Everything the Now Playing extension needs, built from what is on the device.
/// Depends on nothing in the main app, which may be suspended or force-quit.
public struct ExtensionServices: Sendable {
    public let commands: any SessionCommandHandling
    public let tokens: any PushTokenRegistrar
    public let artwork: ArtworkStore
    /// True when commands really go to the relay. For diagnostics.
    public let usesRelay: Bool

    public static func make(
        container: SharedContainer,
        credentials: any CredentialStore,
        http: any HTTPSending = URLSessionHTTP(),
        allowMock: Bool = BuildFlavor.isDebug
    ) -> ExtensionServices {
        let credential: RelayCredential?
        let readFailed: Bool
        do {
            credential = try credentials.load()
            readFailed = false
        } catch {
            credential = nil
            readFailed = true
        }
        if let credential {
            let client = RelayClient(credential: credential, http: http)
            return ExtensionServices(
                commands: RelayCommandHandler(sender: client),
                tokens: RelayPushTokenRegistrar(container: container, client: { client }),
                artwork: ArtworkStore(container: container, fetcher: client),
                usesRelay: true
            )
        }
        // A credential that exists but can't be read must not silently become a mock.
        let commands: any SessionCommandHandling = allowMock && !readFailed ? MockCommandHandler(container: container) : UnpairedCommandHandler()
        return ExtensionServices(
            commands: commands,
            tokens: MockPushTokenRegistrar(container: container),
            artwork: ArtworkStore(container: container),
            usesRelay: false
        )
    }
}
