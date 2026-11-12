import MediaPlayer
import StandByKit

/// Apple Music on this phone for Continue on iPhone, through MediaPlayer's
/// system player. `setQueue(with:)` takes catalogue IDs (store IDs), and
/// `nowPlayingItem.playbackStoreID` gives the playing one back: both seen
/// matching the catalogue on an iPhone on 11 November 2026.
@MainActor
final class SystemMusicPhonePlayer: PhoneMusicPlaying {
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
}
