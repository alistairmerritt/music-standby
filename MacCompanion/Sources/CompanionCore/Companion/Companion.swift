import Foundation
import Observation
import StandByProtocol

/// The Mac companion's engine. Watches Music, publishes `PlaybackMessage`s
/// through a `CompanionTransport`, and applies the phone's `RemoteCommand`s.
///
/// Everything that reads Music or sends frames runs through one serial chain,
/// so state frames leave in revision order and an ack always follows the state
/// it describes. The UI observes the published properties.
@MainActor
@Observable
public final class Companion {
    // MARK: Published state

    public private(set) var snapshot: MusicSnapshot?
    /// The last message produced for the relay.
    public private(set) var message: PlaybackMessage?
    /// Album art for the current track, when it has any.
    public private(set) var artwork: ProcessedArtwork?
    public private(set) var connection: ConnectionStatus = .disconnected
    /// Placeholder until the relay exists: set by a `paired` frame.
    public private(set) var pairedPhone: DeviceIdentity?
    public private(set) var lastAck: CommandAck?
    public private(set) var events: [CompanionEvent] = []

    // MARK: Parts

    @ObservationIgnored public let controller: MusicController
    @ObservationIgnored public let monitor: MusicMonitor
    @ObservationIgnored public let transport: any CompanionTransport
    @ObservationIgnored public let device: DeviceIdentity
    /// Wait between a command and re-reading Music. 0.4 s was verified enough.
    @ObservationIgnored public var settleDelay: Duration = .milliseconds(400)
    /// Called for every event as well as appending it to `events`.
    @ObservationIgnored public var onEvent: ((CompanionEvent) -> Void)?

    @ObservationIgnored private let store: CompanionStore
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var publisher: PlaybackPublisher
    @ObservationIgnored private var artworkByTrack: [String: ArtworkEntry] = [:]
    @ObservationIgnored private var artworkByID: [String: ProcessedArtwork] = [:]
    @ObservationIgnored private var acks: [UUID: CommandAck] = [:]
    @ObservationIgnored private var ackOrder: [UUID] = []
    @ObservationIgnored private var tail: Task<Void, Never>?
    @ObservationIgnored private var listeners: [Task<Void, Never>] = []
    @ObservationIgnored private var started = false
    @ObservationIgnored private var eventCount = 0

    private struct ArtworkEntry {
        var artworkCount: Int
        var artwork: ProcessedArtwork?
        /// Set when extraction failed rather than finding no artwork.
        var failedAt: Date?
    }

    public init(controller: MusicController, transport: any CompanionTransport, store: CompanionStore,
                device: DeviceIdentity, now: @escaping @Sendable () -> Date = { Date() }) {
        self.controller = controller
        self.monitor = MusicMonitor(controller: controller)
        self.transport = transport
        self.store = store
        self.device = device
        self.now = now
        publisher = PlaybackPublisher(revisions: RevisionCounter(lastPersisted: store.lastRevision, now: now()))
    }

    /// The app's companion: real Music.app, mock relay.
    public static func live(transport: any CompanionTransport = MockRelayTransport(), defaults: UserDefaults = .standard) -> Companion {
        let store = CompanionStore(defaults: defaults)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let device = store.deviceIdentity(name: Host.current().localizedName ?? "Mac", appVersion: version)
        return Companion(controller: MusicController(), transport: transport, store: store, device: device)
    }

    // MARK: Lifecycle

    public func start() {
        guard !started else { return }
        started = true
        monitor.onSnapshot = { [weak self] snapshot, trigger in
            self?.enqueue { [weak self] in await self?.ingest(snapshot, trigger: trigger) }
        }
        let inbound = transport.inbound
        let statuses = transport.statusUpdates
        listeners.append(Task { [weak self] in
            for await frame in inbound { await self?.receive(frame) }
        })
        listeners.append(Task { [weak self] in
            for await status in statuses { self?.connectionChanged(status) }
        })
        monitor.start()
        let transport = transport
        let hello = Hello(device: device)
        Task { await transport.connect(hello: hello) }
    }

    /// Says goodbye so the relay needn't wait out its reconnect grace period.
    public func stop() async {
        monitor.stop()
        await serial { [weak self] in await self?.send(.goodbye(reason: "app_quit")) }
        await transport.disconnect()
        listeners.forEach { $0.cancel() }
        listeners.removeAll()
        started = false
    }

    /// Waits until queued reads, commands and sends have finished.
    public func settle() async {
        while let current = tail {
            await current.value
            if tail == current { return }
        }
    }

    // MARK: Local controls (the menu)

    /// The menu's buttons. Same path as a phone command, minus the ack.
    public func perform(_ command: MusicCommand) {
        enqueue { [weak self] in
            guard let self else { return }
            let outcome = controller.perform(command)
            record("menu \(command.rawValue): \(outcome)")
            if outcome == .performed { await settleAndRead() } else { await ingest(await monitor.read(.command), trigger: .command) }
        }
    }

    public func refresh() {
        monitor.requestRead(.start)
    }

    // MARK: Inbound frames

    public func receive(_ frame: RelayFrame) async {
        switch frame {
        case .welcome(let version):
            record("relay welcome, protocol \(version)")
            guard version == StandByWire.version else {
                connection = .failed(ProtocolError(.unsupportedProtocolVersion, message: "relay speaks \(version)"))
                return
            }
            await serial { [weak self] in await self?.sendCurrentState() }
        case .command(let command):
            _ = await handle(command)
        case .unsupportedCommand(let id, let kind):
            await serial { [weak self] in
                guard let self else { return }
                let ack = CommandAck.rejected(id, revision: publisher.latestRevision,
                                              ProtocolError(.unsupportedCommand, message: "unknown command kind \(kind)"))
                remember(ack)
                await send(.ack(ack))
            }
        case .artworkRequest(let id):
            await serial { [weak self] in await self?.serveArtwork(id) }
        case .paired(let phone):
            pairedPhone = phone
            record("paired with \(phone.name)")
        case .revoked(let reason):
            pairedPhone = nil
            record("pairing revoked: \(reason)")
        case .error(let error):
            record("relay error \(error.code): \(error.message ?? "")")
        case .unknown(let type):
            record("ignored unknown frame type \(type)")
        }
    }

    /// Applies a phone command, sends its ack, and returns it. A repeated id
    /// gets the original ack back and does not act twice.
    @discardableResult
    public func handle(_ command: RemoteCommand) async -> CommandAck {
        await serial { [weak self] in
            guard let self else { return .rejected(command.id, revision: 0, ProtocolError(.internal)) }
            let ack = await apply(command)
            await send(.ack(ack))
            return ack
        }
    }

    // MARK: Work on the serial chain

    private func apply(_ command: RemoteCommand) async -> CommandAck {
        if let previous = acks[command.id] {
            record("command \(command.id) repeated; resending its ack")
            return previous
        }
        let ack: CommandAck
        if command.isExpired(at: now()) {
            ack = reject(command, .commandExpired, "issued more than \(Int(RemoteCommand.maximumAge)) s ago")
        } else if command.kind == .next || command.kind == .previous, let snapshot,
                  snapshot.state == .stopped, snapshot.track == nil {
            ack = reject(command, .noCurrentTrack, "nothing is loaded in Music")
        } else {
            switch controller.perform(MusicCommand(command.kind)) {
            case .notRunning:
                ack = reject(command, .musicNotRunning, "Music.app is not running. The companion does not launch it.")
            case .automationDenied(let detail):
                ack = reject(command, .automationDenied, detail)
            case .failed(let detail):
                ack = reject(command, .commandFailed, detail)
            case .performed:
                await settleAndRead()
                ack = .accepted(command.id, revision: publisher.latestRevision)
            }
        }
        remember(ack)
        lastAck = ack
        record("command \(command.kind.rawValue) → \(ack.accepted ? "accepted" : "rejected \(ack.error?.code.rawValue ?? "")") r\(ack.revision)")
        return ack
    }

    private func reject(_ command: RemoteCommand, _ code: ErrorCode, _ message: String) -> CommandAck {
        .rejected(command.id, revision: publisher.latestRevision, ProtocolError(code, message: message))
    }

    private func remember(_ ack: CommandAck) {
        acks[ack.commandID] = ack
        ackOrder.append(ack.commandID)
        if ackOrder.count > 64 { acks[ackOrder.removeFirst()] = nil }
    }

    private func settleAndRead() async {
        try? await Task.sleep(for: settleDelay)
        await ingest(await monitor.read(.command), trigger: .command)
    }

    private func ingest(_ snapshot: MusicSnapshot, trigger: MusicMonitor.Trigger) async {
        // Reads queue behind commands, so one taken before a command's own
        // re-read can arrive after it. Seen against real Music: a notification
        // read from before a pause landed after the pause and briefly said
        // "playing" again. Reads never overlap, so read time is read order.
        if let latest = self.snapshot, snapshot.capturedAt < latest.capturedAt {
            record("dropped a stale \(snapshot.state.rawValue) read [\(trigger.rawValue)]")
            return
        }
        if self.snapshot?.state != snapshot.state || self.snapshot?.track != snapshot.track {
            record("music \(snapshot.state.rawValue)\(snapshot.track.map { ": \($0.title) — \($0.artist)" } ?? "") [\(trigger.rawValue)]")
        }
        self.snapshot = snapshot
        let artworkID = await artworkID(for: snapshot)
        guard let message = publisher.ingest(snapshot, artworkID: artworkID) else { return }
        store.lastRevision = message.revision
        self.message = message
        await send(.state(message))
    }

    private func sendCurrentState() async {
        if let message = publisher.lastSent {
            await send(.state(message))   // same revision: a re-send, not a change
        } else {
            await ingest(await monitor.read(.start), trigger: .start)
        }
    }

    private func artworkID(for snapshot: MusicSnapshot) async -> String? {
        guard let track = snapshot.track else {
            artwork = nil
            return nil
        }
        let key = track.trackID
        if let entry = artworkByTrack[key], entry.artworkCount == track.artworkCount,
           entry.failedAt.map({ now().timeIntervalSince($0) < 30 }) ?? true {
            artwork = entry.artwork
            return entry.artwork?.artworkID
        }
        guard track.artworkCount > 0 else {
            artworkByTrack[key] = ArtworkEntry(artworkCount: 0)
            artwork = nil
            return nil
        }
        let started = now()
        let result = controller.artwork()
        guard case .image(let bytes, let pid, let type) = result else {
            if case .noArtwork = result {
                artworkByTrack[key] = ArtworkEntry(artworkCount: track.artworkCount)
            } else {
                artworkByTrack[key] = ArtworkEntry(artworkCount: track.artworkCount, failedAt: now())
                record("artwork unavailable: \(result)")
            }
            artwork = nil
            return nil
        }
        guard pid == track.persistentID else {
            record("artwork belonged to another track; will retry")
            artwork = nil
            return nil
        }
        let processed = await Task.detached(priority: .utility) { ArtworkProcessor.process(bytes) }.value
        if artworkByTrack.count > 64 { artworkByTrack.removeAll() }
        if artworkByID.count > 64 { artworkByID.removeAll() }
        artworkByTrack[key] = ArtworkEntry(artworkCount: track.artworkCount, artwork: processed,
                                           failedAt: processed == nil ? now() : nil)
        if let processed {
            artworkByID[processed.artworkID] = processed
            let ms = Int(now().timeIntervalSince(started) * 1000)
            record("artwork \(processed.artworkID.prefix(12))… \(bytes.count) bytes '\(type)' \(processed.sourceFormat) → \(processed.descriptor.byteCount) byte JPEG, \(ms) ms")
        } else {
            record("artwork bytes could not be decoded (\(bytes.count) bytes, '\(type)')")
        }
        artwork = processed
        return processed?.artworkID
    }

    private func serveArtwork(_ id: String) async {
        guard let art = artworkByID[id] else {
            await send(.error(ProtocolError(.artworkUnavailable, message: id)))
            return
        }
        do {
            try await transport.uploadArtwork(art.image, descriptor: art.descriptor)
            await send(.artwork(art.descriptor))
        } catch {
            record("artwork upload failed: \(error)")
        }
    }

    private func send(_ frame: MacFrame) async {
        do {
            try await transport.send(frame)
        } catch {
            record("not sent (\(error)): \(frame.summary)")
        }
    }

    private func connectionChanged(_ status: ConnectionStatus) {
        connection = status
        record("connection \(status.phase.rawValue)\(status.peerName.map { " to \($0)" } ?? "")")
    }

    // MARK: Serial chain

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = tail
        tail = Task { await previous?.value; await work() }
    }

    private func serial<T: Sendable>(_ work: @escaping @MainActor () async -> T) async -> T {
        let previous = tail
        let task = Task { await previous?.value; return await work() }
        tail = Task { _ = await task.value }
        return await task.value
    }

    private func record(_ text: String) {
        eventCount += 1
        let event = CompanionEvent(id: eventCount, date: now(), text: text)
        events.append(event)
        if events.count > 100 { events.removeFirst(events.count - 100) }
        onEvent?(event)
    }
}

public struct CompanionEvent: Identifiable, Equatable, Sendable {
    public let id: Int
    public let date: Date
    public let text: String
}

extension MusicCommand {
    public init(_ kind: CommandKind) {
        switch kind {
        case .play: self = .play
        case .pause: self = .pause
        case .next: self = .next
        case .previous: self = .previous
        }
    }
}

extension MacFrame {
    /// One line for logs.
    public var summary: String {
        switch self {
        case .hello(let hello): "hello \(hello.device.name)"
        case .state(let m): "state r\(m.revision) \(m.state.rawValue) \(m.track?.title ?? "-")"
        case .ack(let a): "ack \(a.commandID) \(a.accepted)"
        case .artwork(let a): "artwork \(a.artworkID.prefix(12))…"
        case .goodbye(let reason): "goodbye \(reason)"
        case .error(let e): "error \(e.code)"
        case .unknown(let type): "unknown \(type)"
        }
    }
}
