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

    @ObservationIgnored private let container = SharedContainer.appGroup()
    @ObservationIgnored private let library = MockLibrary.standard
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
        let store = ArtworkStore(container: container)
        let artworkID = track.artworkID
        let artworkURL = track.artworkURL
        return MusicContent(
            id: track.id,
            songTitle: track.title,
            artistName: track.artist,
            albumName: track.album,
            type: .audio,
            duration: .finite(track.duration),
            artwork: Artwork(id: artworkID) { _ in
                try ArtworkRepresentation(data: try await store.resolve(id: artworkID, remoteURL: artworkURL))
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
            .play { self.handle(.play) },
            .pause { self.handle(.pause) },
            .next { self.handle(.next) }.enabled(attributes.canGoNext),
            .previous { self.handle(.previous) }.enabled(attributes.canGoPrevious),
        ]
    }

    var devices: [MediaDevice] {
        [MediaDevice(id: id, name: attributes.macName, type: .desktop, capabilities: [])]
    }

    /// Records the command for the app, wakes it if it is running, and updates
    /// the system UI straight away. Replace the body's log/signal with a real
    /// send to the Mac once the shared transport exists.
    private func handle(_ kind: CommandKind) {
        logger.log("Received command: \(kind.rawValue, privacy: .public)")
        do {
            try CommandLog(container: container).append(CommandRecord(kind: kind, sessionID: id, receivedAt: Date()))
        } catch {
            logger.error("Could not record command: \(error.localizedDescription, privacy: .public)")
        }
        CrossProcessSignal.post(AppGroup.commandSignal)
        attributes = library.applying(kind, to: attributes, at: Date())
    }

    private func startObservingPushToken() {
        let registrar = MockPushTokenRegistrar(container: container)
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
