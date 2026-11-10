import CoreGraphics
import Foundation
import Observation

public struct DiagnosticEntry: Identifiable, Sendable {
    public let id = UUID()
    public let date: Date
    public let message: String
}

@MainActor
@Observable
public final class AppModel {
    public private(set) var hasSeenIntro: Bool
    public private(set) var pairedMac: PairedMac?
    public private(set) var connection: ConnectionState = .disconnected
    public private(set) var attributes: MacPlaybackAttributes?
    public private(set) var artwork: CGImage?
    public private(set) var pushTokens = PushTokens()
    public private(set) var commandsFromSystem: [CommandRecord] = []
    public private(set) var log: [DiagnosticEntry] = []
    public private(set) var isNowPlayingEnabled: Bool
    /// Set while pairing waits for the person at the Mac to allow this phone.
    public private(set) var pairingAwaitingMac: PairedMac?

    public let sessionController: any RemoteSessionControlling
    public let container: SharedContainer

    @ObservationIgnored private let transport: any PlaybackTransport
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let pairingStore: PairingStore
    @ObservationIgnored private let registrar: any PushTokenRegistrar
    @ObservationIgnored private let commandLog: CommandLog
    @ObservationIgnored private let artworkStore: ArtworkStore
    @ObservationIgnored private let policy: SessionLifecyclePolicy
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let sleep: @Sendable (TimeInterval) async throws -> Void
    @ObservationIgnored private var handledCommandIDs: Set<UUID>
    @ObservationIgnored private var commandSignal: CrossProcessSignal?
    @ObservationIgnored private var didSetUp = false
    @ObservationIgnored private var latestMessage: PlaybackMessage?
    @ObservationIgnored private var assignedSessionID: String?
    @ObservationIgnored private var graceDeadline: Date?
    @ObservationIgnored private var graceTask: Task<Void, Never>?
    @ObservationIgnored private var lastRecordedActivationError: String?
    /// A tap older than this is dropped rather than replayed when the app wakes.
    @ObservationIgnored private let commandMaxAge: TimeInterval = 30

    /// True while `start()` is draining the transport's events.
    @ObservationIgnored public private(set) var isConsumingEvents = false

    public init(
        transport: any PlaybackTransport,
        sessionController: any RemoteSessionControlling,
        container: SharedContainer,
        defaults: UserDefaults,
        registrar: any PushTokenRegistrar,
        policy: SessionLifecyclePolicy = SessionLifecyclePolicy(),
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.transport = transport
        self.sessionController = sessionController
        self.container = container
        self.defaults = defaults
        self.registrar = registrar
        self.policy = policy
        self.now = now
        self.sleep = sleep
        pairingStore = PairingStore(defaults: defaults)
        commandLog = CommandLog(container: container)
        artworkStore = ArtworkStore(container: container)
        hasSeenIntro = defaults.bool(forKey: "hasSeenIntro")
        isNowPlayingEnabled = defaults.bool(forKey: "nowPlayingEnabled")
        pairedMac = pairingStore.pairedMac
        // Read into a local: @Observable makes commandsFromSystem computed, so it
        // can't be read until every stored property is initialised.
        let existingCommands = commandLog.all()
        commandsFromSystem = existingCommands
        handledCommandIDs = Set(existingCommands.map(\.id))
        pushTokens = registrar.current()
    }

    /// Drains the transport until cancelled. Safe to call again afterwards: each
    /// run takes a fresh stream, which begins with the transport's current state.
    public func start() async {
        guard !isConsumingEvents else { return }
        isConsumingEvents = true
        defer { isConsumingEvents = false }
        setUpOnce()
        let events = await transport.subscribe()
        if pairedMac != nil { await transport.connect() }
        for await event in events {
            await handle(event)
        }
    }

    private func setUpOnce() {
        guard !didSetUp else { return }
        didSetUp = true
        commandSignal = CrossProcessSignal(name: AppGroup.commandSignal) { [weak self] in
            Task { @MainActor in await self?.processCommandsFromExtension() }
        }
        if !container.isShared {
            record("App Group unavailable: the app and extension can’t share state.")
        }
        Task { await sessionController.observePushToStartTokens(registrar: registrar) }
    }

    /// Runs whenever the scene becomes active, the only moment the system
    /// honours a request to become the primary session, and the recovery point
    /// for anything that couldn't happen in the background.
    public func sceneDidBecomeActive() async {
        if pairedMac != nil { await transport.connect() }
        pushTokens = registrar.current()
        await uploadTokens()
        await processCommandsFromExtension()
        if let graceDeadline, now() >= graceDeadline {
            await endSession(.connectionLost)
        }
        if shouldShowSession, let attributes {
            await activate(with: attributes)
        } else if sessionController.isActive {
            await sessionController.requestPrimary()
        }
    }

    /// Time in the background is not a lost connection. Stop reading the Mac
    /// and drop any countdown; the next foreground reads afresh and reconciles.
    public func sceneDidEnterBackground() async {
        cancelGrace()
        await transport.suspend()
    }

    public func finishIntro() {
        hasSeenIntro = true
        defaults.set(true, forKey: "hasSeenIntro")
    }

    public func pair(rawCode: String) async throws {
        guard let code = PairingCode(rawCode) else { throw TransportError.pairingRejected }
        defer { pairingAwaitingMac = nil }
        let mac = try await transport.pair(code: code) { [weak self] progress in
            await self?.show(progress)
        }
        pairingStore.pairedMac = mac
        pairedMac = mac
        record("Paired with \(mac.name)")
        await uploadTokens()
        await transport.connect()
    }

    private func show(_ progress: PairingProgress) {
        switch progress {
        case .waitingForApproval(let mac):
            pairingAwaitingMac = mac
            record("Waiting for \(mac.name) to allow this iPhone")
        }
    }

    public func reconnect() async {
        record("Reconnecting")
        await transport.reconnect()
    }

    public func unpair() async {
        await endSession(.unpaired)
        await transport.unpair()
        forgetPairing()
        record("Unpaired")
    }

    private func forgetPairing() {
        pairingStore.pairedMac = nil
        pairedMac = nil
        attributes = nil
        artwork = nil
        latestMessage = nil
        assignedSessionID = nil
        setNowPlayingEnabled(false)
    }

    public func activateNowPlaying() async {
        guard let attributes else { return }
        setNowPlayingEnabled(true)
        await sessionController.activate(with: attributes)
        if let error = sessionController.lastError {
            record("Now Playing failed: \(error)")
        } else {
            record("Now Playing session active. Primary: \(sessionController.isSystemPrimary)")
        }
    }

    public func stopNowPlaying() async {
        setNowPlayingEnabled(false)
        await endSession(.userStopped)
    }

    public func send(_ kind: CommandKind) async {
        do {
            let ack = try await transport.send(RemoteCommand(kind: kind, issuedAt: now()))
            if ack.accepted {
                record("Sent \(kind.rawValue); acknowledged at revision \(ack.revision)")
            } else {
                record("Command \(kind.rawValue) refused: \(ack.error?.code.rawValue ?? "no reason given")")
            }
        } catch {
            record("Command \(kind.rawValue) failed: \(error.localizedDescription)")
        }
    }

    public func refreshDiagnostics() {
        pushTokens = registrar.current()
        commandsFromSystem = commandLog.all()
    }

    private func setNowPlayingEnabled(_ enabled: Bool) {
        isNowPlayingEnabled = enabled
        defaults.set(enabled, forKey: "nowPlayingEnabled")
    }

    private func handle(_ event: TransportEvent) async {
        switch event {
        case .connection(let state):
            await apply(connection: state)
        case .playback(let message):
            await apply(playback: message)
        case .sessionAssigned(let id):
            if id != assignedSessionID {
                if sessionController.isActive, sessionController.sessionID != id {
                    await endSession(.replaced)
                }
                assignedSessionID = id
            }
        case .sessionEnded(let reason):
            await endSession(reason)
            assignedSessionID = nil
            attributes = nil
            artwork = nil
            if reason == .pairingRevoked {
                forgetPairing()
                record("The pairing was revoked. Pair with your Mac again.")
            }
        }
    }

    private func apply(connection next: ConnectionState) async {
        let previous = connection
        connection = next
        switch policy.decision(from: previous, to: next) {
        case .keep: break
        case .startGrace: startGrace()
        case .cancelGrace: cancelGrace()
        case .end(let reason): await endSession(reason)
        }
    }

    private func apply(playback message: PlaybackMessage) async {
        guard let mac = pairedMac else { return }
        // A relay names every session. Showing one under a made-up name would
        // leave the Lock Screen with controls the relay refuses.
        if transport.issuesSessionIDs, assignedSessionID == nil { return }
        if let latestMessage, !latestMessage.isSuperseded(by: message) {
            record("Ignored stale revision \(message.revision)")
            return
        }
        latestMessage = message
        let updated = MacPlaybackAttributes(mac: mac, message: message, sessionID: assignedSessionID)
        let previousArtworkID = attributes?.track?.artworkReference
        attributes = updated
        let artworkID = updated.track?.artworkReference
        if artworkID != previousArtworkID {
            if let artworkID {
                await loadArtwork(id: artworkID)
            } else {
                artwork = nil
            }
        }
        if policy.endsSession(message.state) {
            await endSession(.playbackEnded)
        } else if isNowPlayingEnabled, !sessionController.isActive {
            // Includes a previous activation that failed: every update retries it.
            await activate(with: updated)
        } else {
            await sessionController.publish(updated)
        }
    }

    /// Whether a session ought to exist given the latest facts. A connection
    /// that is merely inside its grace period still counts.
    private var shouldShowSession: Bool {
        guard isNowPlayingEnabled, latestMessage?.state.continuesSession != false else { return false }
        switch connection {
        case .connected, .macOffline: return true
        default: return graceDeadline != nil
        }
    }

    private func activate(with attributes: MacPlaybackAttributes) async {
        await sessionController.activate(with: attributes)
        let error = sessionController.lastError
        if let error, error != lastRecordedActivationError {
            record("Now Playing failed: \(error)")
        }
        lastRecordedActivationError = error
    }

    /// The one place a session ends, so the tokens always go with it.
    private func endSession(_ reason: SessionEndReason) async {
        cancelGrace()
        guard sessionController.isActive else { return }
        let id = sessionController.sessionID
        await sessionController.deactivate()
        if let id {
            do {
                try await registrar.invalidate(sessionID: id)
            } catch {
                record("Couldn’t invalidate the session token: \(error.localizedDescription)")
            }
        }
        pushTokens = registrar.current()
        record("Now Playing session ended: \(reason.rawValue)")
    }

    private func uploadTokens() async {
        do {
            try await registrar.uploadStored()
        } catch {
            record("Couldn’t upload push tokens: \(error.localizedDescription)")
        }
    }

    private func startGrace() {
        graceDeadline = now().addingTimeInterval(policy.reconnectGrace)
        graceTask?.cancel()
        let grace = policy.reconnectGrace
        graceTask = Task { [weak self, sleep] in
            do { try await sleep(grace) } catch { return }
            await self?.graceElapsed()
        }
    }

    private func graceElapsed() async {
        guard graceDeadline != nil, !(graceTask?.isCancelled ?? true) else { return }
        await endSession(.connectionLost)
    }

    private func cancelGrace() {
        graceDeadline = nil
        graceTask?.cancel()
        graceTask = nil
    }

    private func loadArtwork(id: String) async {
        do {
            let data = try await transport.artwork(id: id)
            try? artworkStore.save(data, id: id)
            artwork = MockArtwork.decode(data)
        } catch {
            artwork = nil
            record("Artwork failed: \(error.localizedDescription)")
        }
    }

    /// Commands tapped in system UI arrive here from the extension process, when
    /// the mock route recorded them. The relay route never writes to this log.
    private func processCommandsFromExtension() async {
        commandsFromSystem = commandLog.all()
        for record in commandsFromSystem where !handledCommandIDs.contains(record.id) {
            handledCommandIDs.insert(record.id)
            guard now().timeIntervalSince(record.receivedAt) <= commandMaxAge else {
                self.record("Dropped expired \(record.kind.rawValue) from the extension")
                continue
            }
            self.record("System sent \(record.kind.rawValue) to the extension")
            await send(record.kind)
        }
    }

    private func record(_ message: String) {
        log.insert(DiagnosticEntry(date: now(), message: message), at: 0)
        if log.count > 100 { log.removeLast() }
    }
}
