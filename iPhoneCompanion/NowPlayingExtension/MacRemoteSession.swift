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

    init(attributes: MacPlaybackAttributes) {
        id = attributes.id
        self.attributes = attributes
        logger.log("Session created for \(attributes.id, privacy: .public), revision \(attributes.revision)")
        startObservingPushToken()
    }

    func update(_ incoming: MacPlaybackAttributes) {
        guard attributes.shouldBeReplaced(by: incoming) else {
            logger.log("Ignored stale revision \(incoming.revision); holding \(self.attributes.revision)")
            return
        }
        attributes = incoming
    }

    var content: (any MediaContentRepresentable)? {
        guard let track = attributes.track else { return nil }
        let store = services.artwork
        let artworkURL = track.artworkURL
        return MusicContent(
            id: track.id,
            songTitle: track.title,
            artistName: track.artist,
            albumName: track.album,
            type: .audio,
            duration: .finite(track.duration),
            artwork: track.artworkReference.map { artworkID in
                Artwork(id: artworkID) { _ in
                    // PNG encoding never finished inside this extension on iOS 27.2 and the
                    // system kept relaunching it, so generated art skips the encoder.
                    if MockArtwork.isMockID(artworkID), let image = MockArtwork.image(id: artworkID, pixelSize: 300) {
                        return try ArtworkRepresentation(cgImage: image)
                    }
                    return try ArtworkRepresentation(data: try await store.resolve(id: artworkID, remoteURL: artworkURL))
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
            .play { try await self.handle(.play) },
            .pause { try await self.handle(.pause) },
            .next { try await self.handle(.next) }.enabled(attributes.canGoNext),
            .previous { try await self.handle(.previous) }.enabled(attributes.canGoPrevious),
        ]
    }

    var devices: [MediaDevice] {
        [MediaDevice(id: id, name: attributes.macName, type: .desktop, capabilities: [])]
    }

    /// Sends the command from here, so it works while the main app is suspended.
    /// Throwing tells the system it failed. On the relay route the screen shows
    /// the Mac's own result once the relay has it; only the development mock guesses.
    private func handle(_ kind: CommandKind) async throws {
        logger.log("Received command: \(kind.rawValue, privacy: .public), relay: \(self.services.usesRelay)")
        let started = Date()
        do {
            if let result = try await services.commands.perform(kind, on: attributes, at: started) {
                update(result)
                logger.log("Showing revision \(result.revision) after \(kind.rawValue, privacy: .public), \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            } else {
                logger.log("Sent \(kind.rawValue, privacy: .public), no newer state yet, \(Int(Date().timeIntervalSince(started) * 1000)) ms")
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
