import Foundation

/// The Mac as a Shortcuts action reaches it. Like the Now Playing extension,
/// it goes straight to the relay. It has no transport loop and reads nothing
/// from the app's own state, so an action works whether or not the app is
/// running. Each action makes its own, reads the Mac's state once, and sends
/// under the session the relay names at that moment.
@MainActor
public final class MacRemote {
    public typealias Client = CommandSender & SessionReading

    private let client: any Client
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let memory: HandoverMemory
    /// The relay's state as last read. Nil until the first read.
    public private(set) var state: SessionState?

    public init(
        client: any Client,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        memory: HandoverMemory = .none
    ) {
        self.client = client
        self.now = now
        self.sleep = sleep
        self.memory = memory
    }

    /// From the pairing on this device: the credential the extension also
    /// reads. A fresh connection per request, as in the extension, because
    /// iOS can suspend the app between requests.
    public static func paired(credentials: any CredentialStore, http: any HTTPSending = URLSessionHTTP(reuseConnections: false)) throws -> MacRemote {
        guard let credential = try credentials.load() else { throw TransportError.notPaired }
        return MacRemote(client: RelayClient(credential: credential, http: http), memory: .appGroup)
    }

    /// Reads what the relay holds now.
    @discardableResult
    public func read() async throws -> SessionState {
        let fresh = try await client.fetchSession(timeout: RelayClient.defaultTimeout)
        state = fresh
        return fresh
    }

    /// The state from this action's first read.
    public func current() async throws -> SessionState {
        if let state { return state }
        return try await read()
    }

    /// Sends under the relay's current session and returns the Mac's answer,
    /// yes or no. If the session has changed since the read, it reads again and tries once more.
    public func send(_ command: RemoteCommand) async throws -> CommandAck {
        do {
            return try await client.send(command, sessionID: try sessionID(in: try await current()))
        } catch TransportError.commandRejected(.sessionMismatch) {
            return try await client.send(command, sessionID: try sessionID(in: try await read()))
        }
    }

    /// Sends, and throws unless the Mac says yes.
    public func run(_ command: RemoteCommand) async throws {
        let ack = try await send(command)
        guard ack.accepted else { throw TransportError.commandRejected(ack.error?.code ?? .commandFailed) }
    }

    /// Play, pause, next or previous.
    public func run(_ kind: CommandKind) async throws {
        try await run(RemoteCommand(kind: kind, issuedAt: now()))
    }

    /// Pauses a playing Mac and plays one that isn't. Returns what it sent.
    @discardableResult
    public func playOrPause() async throws -> CommandKind {
        let kind: CommandKind = try await current().playback?.state == .playing ? .pause : .play
        try await run(kind)
        return kind
    }

    /// Jumps to `seconds` into the Mac's song. A time at or past the end is
    /// refused: the Mac would run the song to its end and Music would move on
    /// to the next one (seen on 12 November 2026).
    public func seek(to seconds: TimeInterval) async throws {
        if let duration = try await current().playback?.track?.duration, duration > 0, seconds >= duration {
            throw MacRemoteError.pastTheEnd(duration)
        }
        try await run(.seek(to: max(0, seconds), issuedAt: now()))
    }

    /// Music's own volume on the Mac, 0 to 1. Not the Mac's system volume.
    public func setVolume(_ level: Double) async throws {
        try await run(.setVolume(min(max(level, 0), 1), issuedAt: now()))
    }

    /// Continue on iPhone and Continue on Mac from the relay's state. Read
    /// first: with no state, there is nothing to continue.
    public func handover(record: @escaping @MainActor (String) -> Void = { _ in }) -> Handover {
        Handover(
            latest: { [self] in state?.playback },
            refresh: { [self] in _ = try? await read() },
            send: { [self] in try await send($0) },
            record: record,
            now: now,
            sleep: sleep,
            memory: memory
        )
    }

    /// A command needs the current session. Without a connected Mac or a
    /// session, sending would only fail at the relay.
    private func sessionID(in state: SessionState) throws -> String {
        guard state.macConnected else { throw TransportError.notConnected }
        guard let id = state.sessionID else { throw TransportError.commandRejected(.noSession) }
        return id
    }
}

public enum MacRemoteError: Error, Equatable, Sendable, LocalizedError {
    /// A jump to a time the song doesn't reach. Carries the song's length.
    case pastTheEnd(TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .pastTheEnd(let duration):
            "The song on your Mac is only \(Duration.seconds(duration.rounded(.down)).formatted(.time(pattern: .minuteSecond)))."
        }
    }
}
