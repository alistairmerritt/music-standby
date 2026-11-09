import CoreGraphics
import Foundation
import Observation
import StandByKit

struct DiagnosticEntry: Identifiable {
    let id = UUID()
    let date: Date
    let message: String
}

@MainActor
@Observable
final class AppModel {
    private(set) var hasSeenIntro: Bool
    private(set) var pairedMac: PairedMac?
    private(set) var connection: ConnectionState = .disconnected
    private(set) var attributes: MacPlaybackAttributes?
    private(set) var artwork: CGImage?
    private(set) var pushTokens = PushTokens()
    private(set) var commandsFromSystem: [CommandRecord] = []
    private(set) var log: [DiagnosticEntry] = []
    private(set) var isNowPlayingEnabled: Bool

    let sessionController = RemoteSessionController()
    let container = SharedContainer.appGroup()

    @ObservationIgnored private let transport: any PlaybackTransport
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let pairingStore: PairingStore
    @ObservationIgnored private let registrar: MockPushTokenRegistrar
    @ObservationIgnored private let commandLog: CommandLog
    @ObservationIgnored private let artworkStore: ArtworkStore
    @ObservationIgnored private var handledCommandIDs: Set<UUID>
    @ObservationIgnored private var commandSignal: CrossProcessSignal?
    @ObservationIgnored private var didStart = false
    @ObservationIgnored private var isSceneActive = false
    /// A tap older than this is dropped rather than replayed when the app wakes.
    @ObservationIgnored private let commandMaxAge: TimeInterval = 30

    init(transport: any PlaybackTransport = MockTransport()) {
        self.transport = transport
        let defaults = UserDefaults(suiteName: AppGroup.identifier) ?? .standard
        self.defaults = defaults
        pairingStore = PairingStore(defaults: defaults)
        registrar = MockPushTokenRegistrar(container: container)
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

    func start() async {
        guard !didStart else { return }
        didStart = true
        commandSignal = CrossProcessSignal(name: AppGroup.commandSignal) { [weak self] in
            Task { @MainActor in await self?.processCommandsFromExtension() }
        }
        if !container.isShared {
            record("App Group unavailable: the app and extension can’t share state.")
        }
        Task { await sessionController.observePushToStartTokens(registrar: registrar) }
        if pairedMac != nil { await transport.connect() }
        for await event in transport.events {
            await handle(event)
        }
    }

    /// Runs whenever the scene becomes active, the only moment the system
    /// honours a request to become the primary session.
    func sceneDidBecomeActive() async {
        isSceneActive = true
        pushTokens = registrar.current()
        await processCommandsFromExtension()
        if isNowPlayingEnabled, let attributes {
            await sessionController.activate(with: attributes)
        }
    }

    func sceneDidLeaveActive() {
        isSceneActive = false
    }

    func finishIntro() {
        hasSeenIntro = true
        defaults.set(true, forKey: "hasSeenIntro")
    }

    func pair(rawCode: String) async throws {
        guard let code = PairingCode(rawCode) else { throw TransportError.pairingRejected }
        let mac = try await transport.pair(code: code)
        pairingStore.pairedMac = mac
        pairedMac = mac
        record("Paired with \(mac.name)")
        await transport.connect()
    }

    func reconnect() async {
        record("Reconnecting")
        await transport.disconnect()
        await transport.connect()
    }

    func unpair() async {
        await sessionController.deactivate()
        await transport.disconnect()
        pairingStore.pairedMac = nil
        pairedMac = nil
        attributes = nil
        artwork = nil
        setNowPlayingEnabled(false)
        record("Unpaired")
    }

    func activateNowPlaying() async {
        guard let attributes else { return }
        setNowPlayingEnabled(true)
        await sessionController.activate(with: attributes)
        if let error = sessionController.lastError {
            record("Now Playing failed: \(error)")
        } else {
            record("Now Playing session active. Primary: \(sessionController.isSystemPrimary)")
        }
    }

    func stopNowPlaying() async {
        setNowPlayingEnabled(false)
        await sessionController.deactivate()
        record("Now Playing session ended")
    }

    func send(_ kind: CommandKind) async {
        do {
            let ack = try await transport.send(RemoteCommand(kind: kind))
            record("Sent \(kind.rawValue); acknowledged at revision \(ack.revision)")
        } catch {
            record("Command \(kind.rawValue) failed: \(error.localizedDescription)")
        }
    }

    func refreshDiagnostics() {
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
            connection = state
        case .playback(let message):
            guard let mac = pairedMac else { return }
            let updated = MacPlaybackAttributes(mac: mac, message: message)
            let previousArtworkID = attributes?.track?.artworkID
            attributes = updated
            if let artworkID = updated.track?.artworkID, artworkID != previousArtworkID {
                await loadArtwork(id: artworkID)
            }
            // On a cold launch the first state arrives after the scene is active.
            if isNowPlayingEnabled, isSceneActive, !sessionController.isActive {
                await sessionController.activate(with: updated)
            } else {
                await sessionController.publish(updated)
            }
        }
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

    /// Commands tapped in system UI arrive here from the extension process.
    private func processCommandsFromExtension() async {
        commandsFromSystem = commandLog.all()
        for record in commandsFromSystem where !handledCommandIDs.contains(record.id) {
            handledCommandIDs.insert(record.id)
            guard Date().timeIntervalSince(record.receivedAt) <= commandMaxAge else {
                self.record("Dropped expired \(record.kind.rawValue) from the extension")
                continue
            }
            self.record("System sent \(record.kind.rawValue) to the extension")
            await send(record.kind)
        }
    }

    private func record(_ message: String) {
        log.insert(DiagnosticEntry(date: Date(), message: message), at: 0)
        if log.count > 100 { log.removeLast() }
    }
}
