import Foundation

/// Simulated Mac. Holds a small player so commands produce real state changes.
/// Development builds without a relay run on it, and so does the demo.
public actor MockTransport: PlaybackTransport {
    public static let rejectedCode = "000000"

    private var hub = TransportEventHub()
    private let library: MockLibrary
    private let now: @Sendable () -> Date
    private let mac: PairedMac

    private var isConnected = false
    private var index = 0
    private var isPlaying = true
    private var elapsed: TimeInterval = 0
    private var anchor: Date
    private var revision: UInt64 = 0
    private var volume = 0.5
    private var outputs: [AudioOutput]

    /// Moves on to the next song when this one ends, as a Mac does.
    private var songEnd: Task<Void, Never>?
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    /// Whether Music on the simulated Mac says it's connected, for Continue Listening. Nil says nothing, as Macs before 16 November 2026 did.
    private let musicConnection: MusicConnection?

    /// `startingAt`, `elapsed`, `isPlaying` and `musicConnection` set the scene
    /// for development builds' screenshots; the demo starts at the first song.
    /// `revision` is where its revisions count from: a relaunch must count
    /// above the last, or the Now Playing extension keeps the old state.
    public init(library: MockLibrary = .standard, mac: PairedMac = PairedMac(id: "mock", name: "Mock Mac"),
                startingAt index: Int = 0, elapsed: TimeInterval = 0, isPlaying: Bool = true, musicConnection: MusicConnection? = nil,
                revision: UInt64 = 0, now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.library = library
        self.mac = mac
        self.now = now
        self.index = library.tracks.indices.contains(index) ? index : 0
        self.elapsed = elapsed
        self.isPlaying = isPlaying
        self.musicConnection = musicConnection
        self.revision = revision
        self.sleep = sleep
        anchor = now()
        // The Mac's own speakers carry its name, as Music's do.
        outputs = [
            AudioOutput(id: "name:\(mac.name)", name: mac.name, kind: .computer, isSelected: true),
            AudioOutput(id: "aa:bb:cc:dd:ee:01", name: "Kitchen HomePod", kind: .homePod, isSelected: false),
            AudioOutput(id: "aa:bb:cc:dd:ee:02", name: "Living Room Apple TV", kind: .appleTV, isSelected: false, isAvailable: false),
        ]
    }

    public func subscribe() -> AsyncStream<TransportEvent> {
        hub.subscribe()
    }

    public func connect() async {
        guard !isConnected else { return }
        hub.send(.connection(.connecting))
        isConnected = true
        hub.send(.connection(.connected(macName: mac.name)))
        emitPlayback()
    }

    public func reconnect() async {
        hub.send(.connection(.connecting))
        isConnected = true
        hub.send(.connection(.connected(macName: mac.name)))
        emitPlayback()
    }

    public func disconnect() async {
        isConnected = false
        songEnd?.cancel()
        songEnd = nil
        hub.send(.connection(.disconnected))
    }

    public func unpair() async {
        await disconnect()
        hub.reset()
    }

    public func pair(code: PairingCode, progress: @escaping @Sendable (PairingProgress) async -> Void) async throws -> PairedMac {
        guard code.value != Self.rejectedCode else { throw TransportError.pairingRejected }
        return mac
    }

    public func send(_ command: RemoteCommand) async throws -> CommandAck {
        guard isConnected else { throw TransportError.notConnected }
        let date = now()
        switch command.kind {
        case .play, .pause:
            elapsed = position(at: date)
            isPlaying = command.kind == .play
        case .next:
            index = library.index(after: index)
            elapsed = 0
        case .previous:
            index = library.index(before: index)
            elapsed = 0
        case .seek:
            guard let position = command.position else { return rejected(command) }
            elapsed = min(max(0, position), library.tracks[index].duration)
        case .setVolume:
            guard let level = command.level else { return rejected(command) }
            elapsed = position(at: date)
            volume = min(1, max(0, level))
        case .selectOutput:
            guard let id = command.outputID, let chosen = outputs.firstIndex(where: { $0.id == id }) else { return rejected(command) }
            elapsed = position(at: date)
            for i in outputs.indices { outputs[i].isSelected = i == chosen }
        case .playStation:
            // The mock has no stations: the next song plays.
            guard command.hasRequiredValue else { return rejected(command) }
            index = library.index(after: index)
            elapsed = 0
            isPlaying = true
        }
        anchor = date
        emitPlayback()
        return CommandAck(commandID: command.id, accepted: true, revision: revision)
    }

    private func rejected(_ command: RemoteCommand) -> CommandAck {
        .rejected(command.id, revision: revision, ProtocolError(.invalidRequest, message: "\(command.kind.rawValue) needs its value"))
    }

    public func artwork(id: String) async throws -> Data {
        guard MockArtwork.isMockID(id), let data = MockArtwork.data(id: id) else { throw TransportError.artworkUnavailable }
        return data
    }

    private func position(at date: Date) -> TimeInterval {
        let running = isPlaying ? max(0, date.timeIntervalSince(anchor)) : 0
        return min(elapsed + running, library.tracks[index].duration)
    }

    /// The songs follow on by themselves while playing: when one ends, the
    /// next starts, carrying on for any time since (16 November 2026).
    private func scheduleSongEnd() {
        songEnd?.cancel()
        songEnd = nil
        guard isConnected, isPlaying else { return }
        let remaining = max(0, library.tracks[index].duration - position(at: now()))
        let sleep = self.sleep
        songEnd = Task { [weak self] in
            try? await sleep(remaining)
            guard !Task.isCancelled else { return }
            await self?.songEnded()
        }
    }

    private func songEnded() {
        let date = now()
        var position = elapsed + (isPlaying ? max(0, date.timeIntervalSince(anchor)) : 0)
        guard isConnected, isPlaying, position >= library.tracks[index].duration else { return scheduleSongEnd() }
        while position >= library.tracks[index].duration {
            position -= library.tracks[index].duration
            index = library.index(after: index)
        }
        elapsed = position
        anchor = date
        emitPlayback()
    }

    private func emitPlayback() {
        scheduleSongEnd()
        revision += 1
        hub.send(.playback(PlaybackMessage(
            revision: revision,
            state: isPlaying ? .playing : .paused,
            elapsedTime: elapsed,
            capturedAt: anchor,
            track: library.tracks[index],
            canGoNext: true,
            canGoPrevious: true,
            volume: volume,
            outputs: outputs,
            musicConnection: musicConnection
        )))
    }
}
