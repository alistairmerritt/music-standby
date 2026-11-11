import Foundation
import Observation
import os
import StandByProtocol

/// The Mac companion's engine. Watches Music, publishes `PlaybackMessage`s
/// through a `CompanionTransport`, and applies the phone's `RemoteCommand`s.
///
/// Everything that reads Music or sends frames runs through one serial chain,
/// so state frames leave in revision order. A phone command is acknowledged as
/// soon as Music takes it; the state showing its result follows, with a later
/// revision (PROTOCOL.md §5). The UI observes the published properties.
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
    /// Set by the relay's `paired` frame, cleared by `revoked`.
    public private(set) var pairedPhone: DeviceIdentity?
    /// Phones waiting for the person at the Mac to allow them.
    public private(set) var pairRequests: [PairRequest] = []
    public private(set) var lastAck: CommandAck?
    public private(set) var events: [CompanionEvent] = []

    // MARK: Parts

    @ObservationIgnored public let controller: MusicController
    @ObservationIgnored public let monitor: MusicMonitor
    @ObservationIgnored public let transport: any CompanionTransport
    @ObservationIgnored public let device: DeviceIdentity
    /// Wait between a command and re-reading Music. 0.4 s was verified enough.
    @ObservationIgnored public var settleDelay: Duration = .milliseconds(400)
    /// How long after a track change Music's artwork isn't trusted. Music can
    /// report the previous track's image in that time, then none at all. Was
    /// 1.5 s; 0.75 s since 11 Nov 2026, as the previous track's image from
    /// another album is caught and read again anyway (`isStale`).
    @ObservationIgnored public var artworkSettle: TimeInterval = 0.75
    /// How soon Music is asked again after handing out the previous track's
    /// image, rather than waiting for the next poll.
    static let staleArtworkRetry: TimeInterval = 0.5
    @ObservationIgnored private var settleRead: Task<Void, Never>?
    /// Artwork the relay has from this connection, so it isn't sent twice.
    @ObservationIgnored private var uploadedArtwork: Set<String> = []
    /// How long a state waits for its artwork's upload. The phone gets about
    /// a second after each update to fetch the image, so the relay should
    /// already have it; past this the state goes anyway and the relay asks.
    static let uploadAheadLimit: Duration = .seconds(2)
    /// Called for every event as well as appending it to `events`.
    @ObservationIgnored public var onEvent: ((CompanionEvent) -> Void)?
    /// Called once when the relay refuses or revokes this Mac's credential, so
    /// the owner can register afresh and reconnect.
    @ObservationIgnored public var onCredentialsRejected: (() -> Void)?
    /// Allows every pair request without asking. For scripted local tests
    /// only (`msbctl watch --auto-approve`); the app never sets it.
    @ObservationIgnored public var autoApprovePairing = false

    @ObservationIgnored private let store: CompanionStore
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var publisher: PlaybackPublisher
    @ObservationIgnored private var artworkByTrack: [String: ArtworkEntry] = [:]
    /// The track whose artwork is being shown, and since when.
    @ObservationIgnored private var shownTrack: (id: String, album: String, albumKey: String?, since: Date)?
    /// The artwork the previous track had, to catch Music still handing it out,
    /// and to stand in for the next song from the same album.
    @ObservationIgnored private var previousArtwork: (trackID: String, album: String, albumKey: String?, artworkID: String)?
    /// After a skip Music can go on returning the previous track's image for
    /// the new one: for 0.9 s once, for a whole track another time (11 Nov
    /// 2026). An identical image from a different album is read again during
    /// this window, then taken as Music having none, so the catalogue's is used.
    static let staleArtworkWindow: TimeInterval = 4
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

    @ObservationIgnored private let artworkLookup: (any CatalogArtworkLookup)?
    @ObservationIgnored private var catalogArtwork: [String: CatalogEntry] = [:]
    static let catalogRetryAfterFailure: TimeInterval = 60
    static let catalogRetryAfterNoMatch: TimeInterval = 1800

    private enum CatalogEntry {
        case pending
        case found(ProcessedArtwork)
        case missing(retryAt: Date)
    }

    /// `artworkLookup` supplies art for tracks Music has none for; nil means
    /// Music's own artwork only.
    public init(controller: MusicController, transport: any CompanionTransport, store: CompanionStore,
                device: DeviceIdentity, artworkLookup: (any CatalogArtworkLookup)? = nil,
                now: @escaping @Sendable () -> Date = { Date() },
                isMusicLaunching: @escaping () -> Bool = MusicController.isMusicLaunching) {
        self.controller = controller
        self.monitor = MusicMonitor(controller: controller, isLaunching: isMusicLaunching)
        self.transport = transport
        self.store = store
        self.device = device
        self.artworkLookup = artworkLookup
        self.now = now
        publisher = PlaybackPublisher(revisions: RevisionCounter(lastPersisted: store.lastRevision, now: now()),
                                      resuming: store.listeningSession(now: now()))
    }

    /// The app's companion: real Music.app, mock relay unless given one, and
    /// catalogue artwork unless `catalogArtwork` is set to false in `defaults`.
    public static func live(transport: any CompanionTransport = MockRelayTransport(), defaults: UserDefaults = .standard) -> Companion {
        let store = CompanionStore(defaults: defaults)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let device = store.deviceIdentity(name: Host.current().localizedName ?? "Mac", appVersion: version)
        let lookup: (any CatalogArtworkLookup)? = (defaults.object(forKey: "catalogArtwork") as? Bool) == false ? nil : ITunesCatalogArtwork()
        return Companion(controller: MusicController(), transport: transport, store: store, device: device, artworkLookup: lookup)
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
            await monitor.waitOutLaunch()
            let outcome = await controller.perform(command)
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
        case .pairRequest(let request):
            pairRequests.removeAll { $0.claimID == request.claimID }
            pairRequests.append(request)
            record("\(request.phone.name) asks to pair")
            if autoApprovePairing { decidePairing(request.claimID, approved: true) }
        case .paired(let phone):
            pairedPhone = phone
            pairRequests.removeAll()
            record("paired with \(phone.name)")
        case .revoked(let reason):
            pairedPhone = nil
            pairRequests.removeAll()
            record("pairing revoked: \(reason)")
        case .error(let error):
            record("relay error \(error.code): \(error.message ?? "")")
        case .unknown(let type):
            record("ignored unknown frame type \(type)")
        }
    }

    /// Applies a phone command, sends its ack, and returns it. A repeated id
    /// gets the original ack back and does not act twice. When Music took the
    /// command, a re-read is queued straight after the ack.
    @discardableResult
    public func handle(_ command: RemoteCommand) async -> CommandAck {
        await serial { [weak self] in
            guard let self else { return .rejected(command.id, revision: 0, ProtocolError(.internal)) }
            let (ack, performed) = await apply(command)
            await send(.ack(ack))
            if performed { enqueue { [weak self] in await self?.settleAndRead() } }
            return ack
        }
    }

    /// Answers a `pair-request`. Only the person at the Mac should call this.
    public func decidePairing(_ claimID: String, approved: Bool) {
        pairRequests.removeAll { $0.claimID == claimID }
        record("pairing \(approved ? "allowed" : "refused")")
        enqueue { [weak self] in await self?.send(.pairDecision(claimID: claimID, approved: approved)) }
    }

    // MARK: Work on the serial chain

    private func apply(_ command: RemoteCommand) async -> (CommandAck, performed: Bool) {
        if let previous = acks[command.id] {
            record("command \(command.id) repeated; resending its ack")
            return (previous, false)
        }
        var performed = false
        let ack: CommandAck
        let skip = command.kind == .next || command.kind == .previous
        if command.isExpired(at: now()) {
            ack = reject(command, .commandExpired, "issued more than \(Int(RemoteCommand.maximumAge)) s ago")
        } else if skip, await currentTrackIsMissing() {
            // Music answers "next track" with nothing loaded as a success that
            // does nothing (seen right after a relaunch), so check first.
            ack = reject(command, .noCurrentTrack, "nothing is loaded in Music")
        } else {
            await monitor.waitOutLaunch()
            switch await controller.perform(MusicCommand(command.kind)) {
            case .notRunning:
                ack = reject(command, .musicNotRunning, "Music.app is not running. The companion does not launch it.")
            case .automationDenied(let detail):
                ack = reject(command, .automationDenied, detail)
            case .failed(let detail):
                ack = reject(command, .commandFailed, detail)
            case .performed:
                performed = true
                ack = .accepted(command.id, revision: publisher.latestRevision)
            }
        }
        remember(ack)
        lastAck = ack
        record("command \(command.kind.rawValue) → \(ack.accepted ? "accepted" : "rejected \(ack.error?.code.rawValue ?? "")") r\(ack.revision)")
        return (ack, performed)
    }

    /// True when Music is running with nothing loaded. Re-reads first if the
    /// last snapshot can't say, e.g. Music was closed or relaunching.
    private func currentTrackIsMissing() async -> Bool {
        guard snapshot?.track == nil else { return false }
        if snapshot?.state != .stopped {
            await ingest(await monitor.read(.command), trigger: .command)
        }
        return snapshot?.state == .stopped && snapshot?.track == nil
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
        if trigger == .launch || trigger == .terminate {
            record("Music \(trigger == .launch ? "launched" : "quit") (NSWorkspace)")
        }
        if self.snapshot?.state != snapshot.state || self.snapshot?.track != snapshot.track {
            record("music \(snapshot.state.rawValue)\(snapshot.track.map { ": \($0.title) — \($0.artist)" } ?? "") [\(trigger.rawValue)]")
        }
        self.snapshot = snapshot
        let artworkID = await artworkID(for: snapshot)
        guard let message = publisher.ingest(snapshot, artworkID: artworkID) else { return }
        store.lastRevision = message.revision
        store.saveListeningSession(message.listeningSessionID, now: now())
        self.message = message
        await uploadAhead(message)
        await send(.state(message))
    }

    private func sendCurrentState() async {
        if let message = publisher.lastSent {
            await uploadAhead(message)
            await send(.state(message))   // same revision: a re-send, not a change
        } else {
            await ingest(await monitor.read(.start), trigger: .start)
        }
    }

    /// Music's own artwork; failing that, when Music has none at all, the
    /// catalogue's. A failed read from Music is retried, not replaced.
    private func artworkID(for snapshot: MusicSnapshot) async -> String? {
        guard let track = snapshot.track else {
            artwork = nil
            return nil
        }
        if shownTrack?.id != track.trackID {
            if let shown = shownTrack, let art = artwork {
                previousArtwork = (shown.id, shown.album, shown.albumKey, art.artworkID)
            }
            shownTrack = (track.trackID, track.album, Self.albumKey(track), now())
        }
        let processed: ProcessedArtwork?
        switch await musicArtwork(for: track) {
        case .found(let art): processed = art
        case .none: processed = catalogArtwork(for: track)
        case .unavailable: processed = nil
        }
        artwork = processed
        return processed?.artworkID
    }

    private enum MusicArtwork {
        case found(ProcessedArtwork)
        /// Music reports no artwork for the track.
        case none
        /// Music has artwork that couldn't be read or decoded this time.
        case unavailable
    }

    private func musicArtwork(for track: MusicTrack) async -> MusicArtwork {
        let key = track.trackID
        if let entry = artworkByTrack[key], entry.artworkCount == track.artworkCount,
           entry.failedAt.map({ now().timeIntervalSince($0) < 30 }) ?? true {
            if let art = entry.artwork { return .found(art) }
            return entry.failedAt == nil ? .none : .unavailable
        }
        guard track.artworkCount > 0 else {
            artworkByTrack[key] = ArtworkEntry(artworkCount: 0)
            return .none
        }
        if let shown = shownTrack, shown.id == key, now().timeIntervalSince(shown.since) < artworkSettle {
            readAgain(key, after: artworkSettle - now().timeIntervalSince(shown.since))
            // Songs from one album share artwork, so the previous song's stands
            // in until Music's can be trusted. Not cached: that read replaces it.
            if let previous = previousArtwork, previous.trackID != key, let album = shown.albumKey,
               previous.albumKey == album, let art = artworkByID[previous.artworkID] {
                return .found(art)
            }
            return .unavailable   // not read, not cached: too soon to trust
        }
        let started = now()
        let result = await controller.artwork()
        guard case .image(let bytes, let pid, let type) = result else {
            if case .noArtwork = result {
                artworkByTrack[key] = ArtworkEntry(artworkCount: track.artworkCount)
                return .none
            }
            artworkByTrack[key] = ArtworkEntry(artworkCount: track.artworkCount, failedAt: now())
            record("artwork unavailable: \(result)")
            return .unavailable
        }
        guard pid == track.persistentID else {
            record("artwork belonged to another track; will retry")
            return .unavailable
        }
        let processed = await Task.detached(priority: .utility) { ArtworkProcessor.process(bytes) }.value
        if let processed, isStale(processed, for: track) {
            if let shown = shownTrack, now().timeIntervalSince(shown.since) < Self.staleArtworkWindow {
                record("artwork matches the previous track's; will read it again")
                readAgain(key, after: Self.staleArtworkRetry)
                return .unavailable   // not cached: the next read tries again
            }
            record("artwork still matches the previous track's; using the catalogue instead")
            artworkByTrack[key] = ArtworkEntry(artworkCount: track.artworkCount)
            return .none
        }
        if artworkByTrack.count > 64 { artworkByTrack.removeAll() }
        if artworkByID.count > 64 { artworkByID.removeAll() }
        artworkByTrack[key] = ArtworkEntry(artworkCount: track.artworkCount, artwork: processed,
                                           failedAt: processed == nil ? now() : nil)
        guard let processed else {
            record("artwork bytes could not be decoded (\(bytes.count) bytes, '\(type)')")
            return .unavailable
        }
        artworkByID[processed.artworkID] = processed
        let ms = Int(now().timeIntervalSince(started) * 1000)
        record("artwork \(processed.artworkID.prefix(12))… \(bytes.count) bytes '\(type)' \(processed.sourceFormat) → \(processed.descriptor.byteCount) byte JPEG, \(ms) ms")
        return .found(processed)
    }

    /// The album a track's artwork belongs to: its name and album artist (or
    /// artist, as streamed tracks report no album artist). Nil without a name.
    static func albumKey(_ track: MusicTrack) -> String? {
        guard !track.album.isEmpty else { return nil }
        let artist = track.albumArtist.flatMap { $0.isEmpty ? nil : $0 } ?? track.artist
        return "\(track.album)\u{1F}\(artist)"
    }

    /// One more read of the track, `after` seconds from now: once Music has had
    /// time to settle on the new track's artwork, or to stop handing out the old.
    private func readAgain(_ key: String, after delay: TimeInterval) {
        settleRead?.cancel()
        let wait = max(0, delay) + 0.05
        settleRead = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self, self.snapshot?.track?.trackID == key else { return }
            self.monitor.requestRead(.poll)
        }
    }

    /// The previous track's image, from another album, moments after a skip:
    /// Music hasn't switched it yet. The same album legitimately shares art.
    private func isStale(_ art: ProcessedArtwork, for track: MusicTrack) -> Bool {
        guard let previous = previousArtwork, previous.trackID != track.trackID,
              previous.artworkID == art.artworkID, previous.album != track.album,
              let shown = shownTrack else { return false }
        return shown.id == track.trackID
    }

    /// The catalogue's art for a track Music has none for. Looked up once per
    /// track, off the serial chain, so the state isn't held up waiting for it;
    /// when it arrives a fresh read follows, and that read carries it.
    private func catalogArtwork(for track: MusicTrack) -> ProcessedArtwork? {
        guard let artworkLookup, !track.title.isEmpty, !track.artist.isEmpty else { return nil }
        let key = track.trackID
        switch catalogArtwork[key] {
        case .found(let art):
            artworkByID[art.artworkID] = art   // may have been trimmed since
            return art
        case .pending:
            return nil
        case .missing(let retryAt) where now() < retryAt:
            return nil
        case .missing, nil:
            break
        }
        if catalogArtwork.count > 128 { catalogArtwork = catalogArtwork.filter { if case .pending = $0.value { true } else { false } } }
        catalogArtwork[key] = .pending
        let query = CatalogQuery(title: track.title, artist: track.artist, album: track.album, duration: track.duration)
        Task { [weak self] in
            let outcome: Result<Data?, any Error>
            do { outcome = .success(try await artworkLookup.artwork(for: query)) } catch { outcome = .failure(error) }
            var processed: ProcessedArtwork?
            if case .success(let bytes?) = outcome {
                processed = await Task.detached(priority: .utility) { ArtworkProcessor.process(bytes) }.value
            }
            self?.finishCatalogLookup(key: key, title: track.title, outcome: outcome, processed: processed)
        }
        return nil
    }

    private func finishCatalogLookup(key: String, title: String, outcome: Result<Data?, any Error>, processed: ProcessedArtwork?) {
        switch outcome {
        case .failure(let error):
            catalogArtwork[key] = .missing(retryAt: now().addingTimeInterval(Self.catalogRetryAfterFailure))
            record("catalogue artwork lookup failed for \(title): \(error)")
        case .success(nil):
            catalogArtwork[key] = .missing(retryAt: now().addingTimeInterval(Self.catalogRetryAfterNoMatch))
            record("no catalogue artwork matches \(title)")
        case .success(.some(let bytes)):
            guard let processed else {
                catalogArtwork[key] = .missing(retryAt: now().addingTimeInterval(Self.catalogRetryAfterNoMatch))
                record("catalogue artwork for \(title) could not be decoded (\(bytes.count) bytes)")
                return
            }
            catalogArtwork[key] = .found(processed)
            artworkByID[processed.artworkID] = processed
            record("catalogue artwork \(processed.artworkID.prefix(12))… for \(title): \(bytes.count) bytes → \(processed.descriptor.byteCount) byte JPEG")
            if snapshot?.track?.trackID == key { monitor.requestRead(.poll) }
        }
    }

    private func serveArtwork(_ id: String) async {
        guard let art = artworkByID[id] else {
            await send(.error(ProtocolError(.artworkUnavailable, message: id)))
            return
        }
        do {
            try await transport.uploadArtwork(art.image, descriptor: art.descriptor)
            uploadedArtwork.insert(id)
            await send(.artwork(art.descriptor))
        } catch {
            record("artwork upload failed: \(error)")
        }
    }

    /// Uploads the artwork a state names before the state goes out. iOS gives
    /// the phone's extension about a second after each update, and a fetch
    /// that waits on an upload the relay asked for only then ran out of time:
    /// the image never arrived (seen on an iPhone, 11 Nov 2026).
    private func uploadAhead(_ message: PlaybackMessage) async {
        guard connection.phase == .connected, let id = message.track?.artworkID,
              !uploadedArtwork.contains(id), let art = artworkByID[id] else { return }
        let transport = self.transport
        let image = art.image, descriptor = art.descriptor
        let outcome = await Self.waitAtMost(Self.uploadAheadLimit) { () -> String? in
            do {
                try await transport.uploadArtwork(image, descriptor: descriptor)
                return nil
            } catch {
                return String(describing: error)
            }
        }
        switch outcome {
        case .some(nil):
            if uploadedArtwork.count > 64 { uploadedArtwork.removeAll() }
            uploadedArtwork.insert(id)
            await send(.artwork(descriptor))
        case .some(let error?):
            record("artwork upload failed: \(error)")
        case nil:
            record("artwork upload still going after \(Self.uploadAheadLimit); sending the state anyway")
        }
    }

    /// `work`'s result, or nil once `limit` passes; the work carries on.
    static func waitAtMost<T: Sendable>(_ limit: Duration, _ work: @escaping @Sendable () async -> T) async -> T? {
        let pending = OSAllocatedUnfairLock<CheckedContinuation<T?, Never>?>(initialState: nil)
        let settle: @Sendable (T?) -> Void = { value in
            let waiting = pending.withLock { continuation -> CheckedContinuation<T?, Never>? in
                defer { continuation = nil }
                return continuation
            }
            waiting?.resume(returning: value)
        }
        return await withCheckedContinuation { continuation in
            pending.withLock { $0 = continuation }
            Task { settle(await work()) }
            Task {
                try? await Task.sleep(for: limit)
                settle(nil)
            }
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
        if status.phase != .connected { uploadedArtwork.removeAll() }
        if status.phase == .failed, let code = status.error?.code, code == .unauthorized || code == .pairingRevoked {
            pairedPhone = nil
            pairRequests.removeAll()
            record("relay refused this Mac's credential (\(code)); registering again")
            onCredentialsRejected?()
        }
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
        case .pairDecision(_, let approved): "pair-decision \(approved)"
        case .error(let e): "error \(e.code)"
        case .unknown(let type): "unknown \(type)"
        }
    }
}
