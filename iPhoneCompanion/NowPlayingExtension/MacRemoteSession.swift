import Foundation
import NowPlaying
import Observation
import StandByKit
import os

/// The Mac's playback as the system sees it. Runs in the extension process.
@MainActor
@Observable
final class MacRemoteSession: RemoteMediaSessionRepresentable {
    typealias Attributes = MacPlaybackAttributes

    let id: String
    private(set) var attributes: MacPlaybackAttributes

    @ObservationIgnored private let services = ExtensionServices.make(container: SharedContainer.appGroup(), credentials: KeychainCredentialStore())
    @ObservationIgnored private let logger = Logger(subsystem: "com.alistairmerritt.MusicStandBy.NowPlaying", category: "session")
    /// The artwork now in the cache. `content` reads it, so a finished fetch
    /// makes the system read the session again and pick the image up.
    private var fetchedArtwork: String?
    @ObservationIgnored private var fetchingArtwork: String?

    init(attributes: MacPlaybackAttributes) {
        id = attributes.id
        self.attributes = attributes
        logger.log("Session created for \(attributes.id, privacy: .public), revision \(attributes.revision)")
        startObservingPushToken()
        prefetchArtwork()
    }

    func update(_ incoming: MacPlaybackAttributes) {
        guard attributes.shouldBeReplaced(by: incoming) else {
            logger.log("Ignored stale revision \(incoming.revision); holding \(self.attributes.revision)")
            return
        }
        attributes = incoming
        prefetchArtwork()
    }

    /// Fetches the track's artwork into the cache as soon as the update
    /// arrives. iOS suspends the extension about a second after an update and
    /// doesn't wake it to draw the player, so a fetch left until the system
    /// asks for the image froze mid-way and finished on the next song (seen on
    /// an iPhone, 11 Nov 2026). The relay already holds the image (the Mac
    /// uploads it first), so the fetch takes about 150 ms. It starts at once;
    /// the expiring activity only asks for more time, which iOS may refuse.
    private func prefetchArtwork() {
        guard let track = attributes.track, let artworkID = track.artworkReference, !MockArtwork.isMockID(artworkID),
              fetchedArtwork != artworkID, fetchingArtwork != artworkID else { return }
        fetchingArtwork = artworkID
        let store = services.artwork, url = track.artworkURL, logger = logger, started = Date()
        logger.log("Fetching artwork \(artworkID.prefix(12), privacy: .public)")
        let fetch = Task { [weak self] in
            do {
                _ = try await store.resolve(id: artworkID, remoteURL: url)
                logger.log("Artwork \(artworkID.prefix(12), privacy: .public) cached in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
                self?.artworkCached(artworkID)
            } catch {
                logger.error("Artwork fetch failed: \(error.localizedDescription, privacy: .public)")
                self?.artworkCached(nil)
            }
        }
        ProcessInfo.processInfo.performExpiringActivity(withReason: "Fetching the song's artwork") { expired in
            guard !expired else { return }
            let done = DispatchSemaphore(value: 0)
            Task {
                await fetch.value
                done.signal()
            }
            _ = done.wait(timeout: .now() + 8)
        }
    }

    private func artworkCached(_ artworkID: String?) {
        fetchingArtwork = nil
        if let artworkID, attributes.track?.artworkReference == artworkID { fetchedArtwork = artworkID }
    }

    var content: (any MediaContentRepresentable)? {
        guard let track = attributes.track else { return nil }
        _ = fetchedArtwork   // observed: a finished fetch re-reads the content
        let store = services.artwork
        let artworkURL = track.artworkURL
        let logger = logger
        // iOS asks for an item's artwork when the item first appears, not when
        // artwork is added to it later: with the song's id alone, art that
        // followed the title (the Mac waits for Music to settle, or the
        // catalogue answers) never showed (seen on an iPhone, 11 Nov 2026).
        return MusicContent(
            id: track.artworkReference.map { "\(track.id)#\($0.prefix(16))" } ?? track.id,
            songTitle: track.title,
            artistName: track.artist,
            albumName: track.album,
            type: .audio,
            duration: .finite(track.duration),
            artwork: track.artworkReference.map { artworkID in
                Artwork(id: artworkID) { size in
                    // PNG encoding never finished inside this extension on iOS 27.2 and the
                    // system kept relaunching it, so generated art skips the encoder.
                    if MockArtwork.isMockID(artworkID), let image = MockArtwork.image(id: artworkID, pixelSize: 300) {
                        return try ArtworkRepresentation(cgImage: image)
                    }
                    let cached = store.load(id: artworkID) != nil
                    logger.log("Artwork \(artworkID.prefix(12), privacy: .public) asked for at \(Int(size.width))x\(Int(size.height)), cached: \(cached)")
                    do {
                        let representation = try ArtworkRepresentation(data: try await store.resolve(id: artworkID, remoteURL: artworkURL))
                        logger.log("Artwork \(artworkID.prefix(12), privacy: .public) handed over")
                        return representation
                    } catch {
                        logger.error("Artwork \(artworkID.prefix(12), privacy: .public) not handed over: \(error.localizedDescription, privacy: .public)")
                        throw error
                    }
                }
            }
        )
    }

    var playbackSnapshot: MediaPlaybackSnapshot? {
        MediaPlaybackSnapshot(
            state: attributes.isPlaying ? .playing() : .paused,
            elapsedTime: attributes.elapsedTime,
            timestamp: attributes.timestamp
        )
    }

    var commands: [MediaCommand] {
        [
            .play { try await self.handle(RemoteCommand(kind: .play, issuedAt: Date())) },
            .pause { try await self.handle(RemoteCommand(kind: .pause, issuedAt: Date())) },
            .next { try await self.handle(RemoteCommand(kind: .next, issuedAt: Date())) }.enabled(attributes.canGoNext),
            .previous { try await self.handle(RemoteCommand(kind: .previous, issuedAt: Date())) }.enabled(attributes.canGoPrevious),
            // Dragging the Lock Screen's progress bar. Added 11 November 2026.
            .seekToPosition { seconds in try await self.handle(.seek(to: seconds, issuedAt: Date())) }
                .enabled((attributes.track?.duration ?? 0) > 0),
        ]
    }

    /// The Mac, with a volume slider when it reports Music's volume. The
    /// slider sets Music's own output volume, not the Mac's.
    var devices: [MediaDevice] {
        let capabilities: [MediaDevice.Capability] = attributes.volume.map { level in
            [.absoluteVolume(Float(level)) { [weak self] newLevel in
                try await self?.setVolume(Double(newLevel))
            }]
        } ?? []
        return [MediaDevice(id: id, name: attributes.macName, type: .desktop, capabilities: capabilities)]
    }

    @ObservationIgnored private var volumeInFlight = false
    @ObservationIgnored private var pendingVolume: Double?

    /// A slider sends many levels in a row. One command is in flight at a
    /// time; the newest level waits and the ones between are dropped.
    private func setVolume(_ level: Double) async throws {
        pendingVolume = level
        guard !volumeInFlight else { return }
        volumeInFlight = true
        defer { volumeInFlight = false }
        while let next = pendingVolume {
            pendingVolume = nil
            try await handle(.setVolume(next, issuedAt: Date()))
        }
    }

    /// Sends the command from here, so it works while the main app is suspended.
    /// Throwing tells the system it failed. On the relay route the screen shows
    /// the Mac's own result once the relay has it; only the development mock guesses.
    private func handle(_ command: RemoteCommand) async throws {
        let name = command.kind.rawValue
        logger.log("Received command: \(name, privacy: .public), relay: \(self.services.usesRelay)")
        let started = Date()
        do {
            if let result = try await services.commands.perform(command, on: attributes) {
                update(result)
                logger.log("Showing revision \(result.revision) after \(name, privacy: .public), \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            } else {
                logger.log("Sent \(name, privacy: .public), no newer state yet, \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            }
        } catch {
            logger.error("Command failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    private func startObservingPushToken() {
        let registrar = services.tokens
        let sessionID = id
        if let token = pushToken {
            Task { try? await registrar.registerUpdateToken(token.hexString, forSessionID: sessionID) }
        }
        Task { [weak self] in
            guard let updates = self?.pushTokenUpdates else { return }
            for await token in updates {
                try? await registrar.registerUpdateToken(token.hexString, forSessionID: sessionID)
            }
        }
    }
}
