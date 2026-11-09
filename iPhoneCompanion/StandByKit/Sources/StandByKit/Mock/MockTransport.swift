import Foundation

/// Simulated Mac. Holds a small player so commands produce real state changes.
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

    public init(library: MockLibrary = .standard, mac: PairedMac = PairedMac(id: "mock", name: "Mock Mac"), now: @escaping @Sendable () -> Date = { Date() }) {
        self.library = library
        self.mac = mac
        self.now = now
        anchor = now()
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
        hub.send(.connection(.disconnected))
    }

    public func unpair() async {
        await disconnect()
        hub.reset()
    }

    public func pair(code: PairingCode) async throws -> PairedMac {
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
        }
        anchor = date
        emitPlayback()
        return CommandAck(commandID: command.id, accepted: true, revision: revision)
    }

    public func artwork(id: String) async throws -> Data {
        guard MockArtwork.isMockID(id), let data = MockArtwork.png(id: id) else { throw TransportError.artworkUnavailable }
        return data
    }

    private func position(at date: Date) -> TimeInterval {
        let running = isPlaying ? max(0, date.timeIntervalSince(anchor)) : 0
        return min(elapsed + running, library.tracks[index].duration)
    }

    private func emitPlayback() {
        revision += 1
        hub.send(.playback(PlaybackMessage(
            revision: revision,
            isPlaying: isPlaying,
            elapsedTime: elapsed,
            capturedAt: anchor,
            track: library.tracks[index],
            canGoNext: true,
            canGoPrevious: true
        )))
    }
}
