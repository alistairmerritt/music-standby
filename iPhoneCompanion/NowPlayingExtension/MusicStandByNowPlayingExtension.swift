import ExtensionFoundation
import NowPlaying
import StandByKit

@main
struct MusicStandByNowPlayingExtension: RemoteMediaSessionExtension {
    var configuration: RemoteMediaSessionExtensionConfiguration<Self> {
        RemoteMediaSessionExtensionConfiguration(extension: self)
    }

    func session(_ attributes: MacPlaybackAttributes) async throws -> MacRemoteSession {
        MacRemoteSession(attributes: attributes)
    }
}
