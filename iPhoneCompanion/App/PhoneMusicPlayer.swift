import MediaPlayer
import MusicKit
import StandByKit

/// Apple Music on this phone for Continue on iPhone, through MediaPlayer's
/// system player. `setQueue(with:)` takes catalogue IDs (store IDs), and
/// `nowPlayingItem.playbackStoreID` gives the playing one back: both seen
/// matching the catalogue on an iPhone on 11 November 2026.
@MainActor
final class SystemMusicPhonePlayer: PhoneMusicPlaying {
    /// Opens the Music app, where Continue on iPhone leaves the song.
    nonisolated static let appURL = URL(string: "music://")!

    private let player = MPMusicPlayerController.systemMusicPlayer

    func requestAccess() async -> Bool {
        switch MPMediaLibrary.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                MPMediaLibrary.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
        default:
            return false
        }
    }

    func play(catalogIDs: [String], position: @escaping @MainActor () -> TimeInterval, timeout: TimeInterval) async -> Bool {
        guard let first = catalogIDs.first else { return false }
        player.setQueue(with: catalogIDs)
        let prepared = await withCheckedContinuation { continuation in
            player.prepareToPlay { continuation.resume(returning: $0 == nil) }
        }
        guard prepared else { return false }
        player.currentPlaybackTime = position()
        player.play()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if player.playbackState == .playing, player.nowPlayingItem?.playbackStoreID == first {
                // Starting can take a moment; land on where the Mac is now.
                let target = position()
                if abs(player.currentPlaybackTime - target) > 1.5 { player.currentPlaybackTime = target }
                return true
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    func nowPlaying() -> PhoneNowPlaying? {
        guard MPMediaLibrary.authorizationStatus() == .authorized, let item = player.nowPlayingItem else { return nil }
        let id = item.playbackStoreID
        return PhoneNowPlaying(catalogID: id.isEmpty || id == "0" ? nil : id, position: player.currentPlaybackTime,
                               isPlaying: player.playbackState == .playing)
    }

    func pause() { player.pause() }

    func resume() { player.play() }

    /// Apple Music's station for the song (MusicKit's `Song.station`, the
    /// catalogue's Create Station), after the queue, through MusicKit's
    /// queue. Seen on the iPhone on 15 November 2026 (`StationProbe`): while
    /// playing, the station's songs kept coming after the Mac's (nine and
    /// counting); Playing Next shows only its next two. MediaPlayer's append
    /// by store ID instead looped the Mac's songs, so it isn't used. The
    /// catalogue needs the MusicKit app service on the App ID.
    func appendStation(seededBy catalogID: String) async -> StationAppend {
        let station: Station
        do {
            var request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(catalogID))
            request.properties = [.station]
            guard let found = try await request.response().items.first?.station else { return .noStation }
            station = found
        } catch {
            return .failed("catalogue: \(error.localizedDescription)")
        }
        do {
            try await SystemMusicPlayer.shared.queue.insert(station, position: .tail)
            return .added
        } catch {
            return .failed("queue: \(error.localizedDescription)")
        }
    }
}
