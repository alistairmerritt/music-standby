import Foundation

/// What a tap on a system control does.
public protocol SessionCommandHandling: Sendable {
    /// Returns attributes to show straight away, or nil to wait for the
    /// authoritative update. Throwing tells the system the command failed.
    /// `command.issuedAt` is when the control was used.
    func perform(_ command: RemoteCommand, on attributes: MacPlaybackAttributes) async throws -> MacPlaybackAttributes?
}

extension SessionCommandHandling {
    /// A plain command (play, pause, next, previous) used at `date`.
    public func perform(_ kind: CommandKind, on attributes: MacPlaybackAttributes, at date: Date) async throws -> MacPlaybackAttributes? {
        try await perform(RemoteCommand(kind: kind, issuedAt: date), on: attributes)
    }
}

/// Reads what the relay holds now.
public protocol SessionReading: Sendable {
    func fetchSession(timeout: TimeInterval) async throws -> SessionState
}

/// The production path: straight to the relay from the extension, whether or
/// not the main app is running.
///
/// Nothing on screen is guessed. Once the Mac has acknowledged the tap, the
/// handler reads the relay's state and shows it, but only if it is for the same
/// session and newer than the acknowledgement: the Mac's own result. Without
/// pushes this is the only way a locked phone learns what its own tap did; on
/// an iPhone, Pause otherwise stayed Pause and the next tap paused again.
/// Changes made at the Mac still need a push.
public struct RelayCommandHandler: SessionCommandHandling {
    /// The Mac acknowledges when Music takes a command and re-reads it about
    /// 0.4 s later, so its result usually reaches the relay within the first wait.
    public static let resultWaits: [TimeInterval] = [0.5, 0.6]
    public static let readTimeout: TimeInterval = 1

    private let sender: any CommandSender
    private let reader: (any SessionReading)?
    private let waits: [TimeInterval]
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    public init(
        sender: any CommandSender,
        reader: (any SessionReading)? = nil,
        waits: [TimeInterval] = RelayCommandHandler.resultWaits,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.sender = sender
        self.reader = reader
        self.waits = waits
        self.sleep = sleep
    }

    public func perform(_ command: RemoteCommand, on attributes: MacPlaybackAttributes) async throws -> MacPlaybackAttributes? {
        // The session on screen, so the relay can refuse a tap on a stale one.
        let ack = try await sender.send(command, sessionID: attributes.id)
        guard ack.accepted else { throw TransportError.commandRejected(ack.error?.code ?? .commandFailed) }
        guard let reader else { return nil }
        // The command has worked by now. Failing to see its result changes nothing.
        for wait in waits {
            do { try await sleep(wait) } catch { return nil }
            guard let state = try? await reader.fetchSession(timeout: Self.readTimeout) else { continue }
            guard state.sessionID == attributes.id else { return nil }
            if let latest = state.attributes, latest.revision > ack.revision, latest.revision >= attributes.revision {
                return MacPlaybackAttributes(latest)
            }
        }
        return nil
    }
}

extension MacPlaybackAttributes {
    /// The relay's push attributes, field for field.
    public init(_ relay: NowPlayingAttributes) {
        self.init(
            id: relay.id,
            macName: relay.macName,
            revision: relay.revision,
            isPlaying: relay.isPlaying,
            elapsedTime: relay.elapsedTime,
            timestamp: relay.timestamp,
            track: relay.track.map {
                SessionTrack(id: $0.id, title: $0.title, artist: $0.artist, album: $0.album, duration: $0.duration,
                             artworkID: $0.artworkID.isEmpty ? nil : $0.artworkID, artworkURL: $0.artworkURL)
            },
            canGoNext: relay.canGoNext,
            canGoPrevious: relay.canGoPrevious,
            volume: relay.volume
        )
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

    public func perform(_ command: RemoteCommand, on attributes: MacPlaybackAttributes) async throws -> MacPlaybackAttributes? {
        let date = command.issuedAt ?? Date()
        // Only bookkeeping for Diagnostics: failing to write it mustn't fail the tap.
        try? log.append(CommandRecord(kind: command.kind, sessionID: attributes.id, receivedAt: date))
        CrossProcessSignal.post(AppGroup.commandSignal)
        return library.applying(command, to: attributes, at: date)
    }
}

/// No pairing, so nowhere to send anything.
public struct UnpairedCommandHandler: SessionCommandHandling {
    public init() {}

    public func perform(_ command: RemoteCommand, on attributes: MacPlaybackAttributes) async throws -> MacPlaybackAttributes? {
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
        for (id, hex) in tokens.sessions {
            do {
                try await client.registerSessionToken(hex, sessionID: id)
            } catch TransportError.commandRejected(.sessionMismatch) {
                // That session is over at the relay. Its token is no use to anyone.
                try? await local.invalidate(sessionID: id)
            }
        }
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
        http: any HTTPSending = URLSessionHTTP(reuseConnections: false),
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
            let client = RelayClient(credential: credential, http: http, artworkPolicy: .forExtension)
            return ExtensionServices(
                commands: RelayCommandHandler(sender: client, reader: client),
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
