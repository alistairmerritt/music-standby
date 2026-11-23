import CoreGraphics
import Foundation
import Observation
import os

private let diagnosticsLog = Logger(subsystem: "com.alistairmerritt.MusicStandBy", category: "diagnostics")

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
    /// Where the Mac can play to, from its last state. Empty when it doesn't say.
    public private(set) var outputs: [AudioOutput] = []
    /// True when the Mac's last state names the song's Apple Music catalogue ID,
    /// so Continue on iPhone can start it here.
    public private(set) var canContinueOnPhone = false
    /// Whether the Mac is connected to Music as a remote, from its newest
    /// state, with or without a session. Nil until a Mac that says has sent
    /// a state (16 November 2026).
    public private(set) var macMusicConnection: MusicConnection?
    /// The Mac has a song, but no Apple Music catalogue ID for it: Continue
    /// on iPhone looks it up in the phone's Apple Music first (16 November
    /// 2026).
    public private(set) var macSongHasNoCatalogID = false
    public private(set) var artwork: CGImage?
    public private(set) var pushTokens = PushTokens()
    public private(set) var commandsFromSystem: [CommandRecord] = []
    public private(set) var log: [DiagnosticEntry] = []
    public private(set) var isNowPlayingEnabled: Bool
    /// Set while pairing waits for the person at the Mac to allow this phone.
    public private(set) var pairingAwaitingMac: PairedMac?
    /// True while the demo's simulated Mac stands in for a paired one.
    public private(set) var isDemo: Bool
    /// The Mac's song and whether it's playing, from its latest state, with or
    /// without a Now Playing session. The first run's "Play something" step
    /// shows it before the relay has named a session, which it does only once
    /// the Mac plays (16 November 2026).
    public private(set) var macTrack: TrackMetadata?
    public private(set) var macIsPlaying = false

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
        isDemo = (transport as? any DemoSwitching)?.isInDemo ?? false
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
        // While this iPhone plays and the Mac doesn't, as after Continue on
        // iPhone, the phone's music keeps the system player: asking here put
        // the Mac's paused song in Control Centre whenever Second Chair was
        // open (17 November 2026). StandBy already preferred the phone's.
        let deferToPhone = phonePlaysMusic() && attributes?.isPlaying != true
        if shouldShowSession, let attributes {
            await activate(with: attributes, requestingPrimary: !deferToPhone)
        } else if sessionController.isActive, !deferToPhone {
            await sessionController.requestPrimary()
        }
    }

    /// Whether Apple Music on this iPhone is playing. The app sets it; Second
    /// Chair then leaves the system player to the phone's music on opening
    /// while the Mac is paused (17 November 2026).
    @ObservationIgnored public var phonePlaysMusic: @MainActor () -> Bool = { false }

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
        // Showing is on from the start: the Mac's first song puts the player on
        // the Lock Screen while the app is still open, which iOS requires. There's
        // no Show in Now Playing button to miss (first run V2, 16 November 2026).
        setNowPlayingEnabled(true)
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

    /// Whether this build can offer the demo.
    public var canTryDemo: Bool { transport is any DemoSwitching }

    /// The simulated Mac, treated as paired. Only from the pairing screen:
    /// a real pairing is never set aside for it.
    public func startDemo() async {
        guard pairedMac == nil, let switcher = transport as? any DemoSwitching else { return }
        let mac = await switcher.startDemo()
        defaults.set(true, forKey: DemoMode.key)
        isDemo = true
        pairingStore.pairedMac = mac
        pairedMac = mac
        record("Started the demo")
        await transport.connect()
    }

    /// Ends the demo's Now Playing and goes back to pairing.
    public func leaveDemo() async {
        guard isDemo, let switcher = transport as? any DemoSwitching else { return }
        await unpair()
        await switcher.endDemo()
        defaults.set(false, forKey: DemoMode.key)
        isDemo = false
        record("Left the demo")
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
        macTrack = nil
        macIsPlaying = false
        assignedSessionID = nil
        macMusicConnection = nil
        macSongHasNoCatalogID = false
        setNowPlayingEnabled(false)
    }

    /// Show in Now Playing, and the reminder's tap. Turns showing on even
    /// before the Mac's state has arrived: the next state then activates it.
    public func activateNowPlaying() async {
        setNowPlayingEnabled(true)
        guard let attributes, attributes.track != nil else { return }
        await sessionController.activate(with: attributes)
        if let error = sessionController.lastError {
            record("Now Playing failed: \(error)")
        } else {
            record("Now Playing session active. Primary: \(sessionController.isSystemPrimary)")
        }
    }

    /// `activateNowPlaying` from a Shortcuts action that runs in the background,
    /// where nothing has the event loop running: listens for the Mac's state
    /// until it has a song, then shows the player. False when no song arrived
    /// within `timeout`, so the caller can open the app instead.
    ///
    /// On 19 November 2026, with the phone locked and the player dismissed, this
    /// showed the player on the Lock Screen about 20 s after the Mac started
    /// playing, without opening the app.
    public func activateNowPlaying(waitingForTheMacFor timeout: Duration) async -> Bool {
        // Already running when the app is open; then this ends at once.
        let listening = Task { await start() }
        defer { listening.cancel() }
        let step = Duration.milliseconds(50)
        var waited = Duration.zero
        while attributes?.track == nil, waited < timeout {
            try? await Task.sleep(for: step)
            waited += step
        }
        guard attributes?.track != nil else { return false }
        await activateNowPlaying()
        return true
    }

    /// iOS refused to make the player the system's own the last time it was
    /// asked: error 5 for a request from the background while another player
    /// (Apple Music) holds the Lock Screen, seen on 21 November 2026. Only an
    /// app on screen can then take it.
    public var primaryWasRefused: Bool { sessionController.lastPrimaryError != nil }

    public func stopNowPlaying() async {
        setNowPlayingEnabled(false)
        // A session from an earlier run that this one hasn't picked up yet,
        // as when a Shortcuts action stops showing without opening the app.
        if !sessionController.isActive { await sessionController.adoptExisting() }
        await endSession(.userStopped)
    }

    public func send(_ kind: CommandKind) async {
        await send(RemoteCommand(kind: kind, issuedAt: now()))
    }

    /// Jump to `seconds` into the current track on the Mac.
    public func seek(to seconds: TimeInterval) async {
        await send(.seek(to: seconds, issuedAt: now()))
    }

    /// Set Music's own output volume on the Mac, 0 to 1.
    public func setVolume(_ level: Double) async {
        await send(.setVolume(level, issuedAt: now()))
    }

    /// Play to this output alone. `id` is an `AudioOutput.id` from `outputs`.
    public func selectOutput(_ id: String) async {
        await send(.selectOutput(id, issuedAt: now()))
    }

    /// Continue on iPhone, from the Mac's live state. See `Handover`.
    /// `arrived` runs the moment the music starts here, before the rest of
    /// the hand-over finishes.
    public func continueOnPhone(with player: any PhoneMusicPlaying, timeout: TimeInterval = 10,
                                arrived: (@MainActor () -> Void)? = nil) async -> ContinueOutcome {
        await handover.continueOnPhone(with: player, timeout: timeout, arrived: arrived)
    }

    /// How many songs ahead in the Mac's queue this catalogue ID is: 0 for
    /// the Mac's current song, 1 for the first of its Up Next. Nil when the
    /// Mac's last state doesn't have it.
    public func macQueuePosition(of catalogID: String?) -> Int? {
        handover.macQueuePosition(of: catalogID)
    }

    /// Continue on Mac, from the Mac's live state. See `Handover`.
    /// `arrived` runs the moment the Mac is seen playing, before the rest of
    /// the hand-over finishes.
    public func sendBackToMac(with player: any PhoneMusicPlaying, timeout: TimeInterval = 10,
                              arrived: (@MainActor () -> Void)? = nil) async -> SendBackOutcome {
        await handover.sendBackToMac(with: player, timeout: timeout, arrived: arrived)
    }

    /// The handover steps, reading the Mac through this model's transport.
    private var handover: Handover {
        Handover(
            latest: { [weak self] in self?.latestMessage },
            refresh: { [transport] in await transport.refreshState() },
            send: { [transport] in try await transport.send($0) },
            record: { [weak self] in self?.record($0) },
            now: now,
            sleep: sleep,
            memory: .defaults(defaults)
        )
    }

    public func send(_ command: RemoteCommand) async {
        let name = command.kind.rawValue
        do {
            let ack = try await transport.send(command)
            if ack.accepted {
                record("Sent \(name); acknowledged at revision \(ack.revision)")
            } else {
                record("Command \(name) refused: \(ack.error?.code.rawValue ?? "no reason given")")
            }
        } catch {
            record("Command \(name) failed: \(error.localizedDescription)")
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
            canContinueOnPhone = false
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
        if let latestMessage, !latestMessage.isSuperseded(by: message) {
            record("Ignored stale revision \(message.revision)")
            return
        }
        // Continue Listening works from the Mac's state with or without a
        // Now Playing session: before the session check below. With it after,
        // Continue on iPhone never appeared while the player wasn't showing,
        // though the status said Ready (16 November 2026).
        latestMessage = message
        macTrack = message.track
        macIsPlaying = message.state == .playing
        macMusicConnection = message.musicConnection
        outputs = message.outputs ?? []
        // Any song: one the Mac has no catalogue ID for is looked up here.
        canContinueOnPhone = message.track != nil
        macSongHasNoCatalogID = message.track != nil && message.track?.catalogID == nil
        // A relay names every session. Showing one under a made-up name would
        // leave the Lock Screen with controls the relay refuses.
        if transport.issuesSessionIDs, assignedSessionID == nil { return }
        var updated = MacPlaybackAttributes(mac: mac, message: message, sessionID: assignedSessionID)
        // Once Music stops or quits the Mac reports no track. Keep the last one,
        // paused, in the same session: iOS shows only a session the app asked
        // for while open, so ending this one would leave the next song hidden
        // until the app is opened again.
        if updated.track == nil, let previous = attributes?.track { updated.track = previous }
        let previousArtworkID = attributes?.track?.artworkReference
        attributes = updated
        // The Continue Listening widget's picture. Not the demo's songs.
        if !isDemo { WidgetSnapshot.publish(updated) }
        let artworkID = updated.track?.artworkReference
        if artworkID != previousArtworkID {
            if let artworkID {
                await loadArtwork(id: artworkID)
            } else {
                artwork = nil
            }
        }
        if isNowPlayingEnabled, !sessionController.isActive, updated.track != nil {
            // Includes a previous activation that failed: every update retries it.
            await activate(with: updated)
        } else {
            await sessionController.publish(updated)
        }
    }

    /// Whether a session ought to exist given the latest facts. A connection
    /// that is merely inside its grace period still counts.
    private var shouldShowSession: Bool {
        guard isNowPlayingEnabled, attributes?.track != nil else { return false }
        switch connection {
        case .connected, .macOffline: return true
        default: return graceDeadline != nil
        }
    }

    private func activate(with attributes: MacPlaybackAttributes, requestingPrimary: Bool = true) async {
        await sessionController.activate(with: attributes, requestingPrimary: requestingPrimary)
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
        // Also to the device log, so background runs (the reminder, Shortcuts)
        // can be read over a cable, not only in Diagnostics.
        diagnosticsLog.notice("\(message, privacy: .public)")
        log.insert(DiagnosticEntry(date: now(), message: message), at: 0)
        if log.count > 100 { log.removeLast() }
    }
}
