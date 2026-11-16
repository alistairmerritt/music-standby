#if DEBUG
import Foundation
import StandByKit
import UIKit

/// Development builds only: the demo's songs on this phone, laid out as a
/// paired Mac's, for App Store screenshots, without unpairing the real Mac
/// (16 November 2026).
///
///     xcrun devicectl device process launch --device <udid> --terminate-existing \
///         com.alistairmerritt.MusicStandBy -- -screenshotDemo [-screenshotSong N] [-screenshotPaused]
///
/// `N` is 1 to 6, in `MockLibrary.standard`'s order. The song starts 1:12 in
/// and shows in Now Playing straight away. The interface stays portrait,
/// even on a charger on its side. Settings live in their own defaults suite
/// and the Keychain is never read, so the real pairing is untouched; push
/// tokens go nowhere. To go back, launch without the switch and pass
/// `-showNowPlaying`. Lock Screen controls do nothing meanwhile: the
/// extension still holds the real pairing.
@MainActor
enum ScreenshotMode {
    static var isOn: Bool { ProcessInfo.processInfo.arguments.contains("-screenshotDemo") }

    private static let suite = "com.alistairmerritt.MusicStandBy.screenshots"
    private static let mac = PairedMac(id: DemoMode.mac.id, name: "MacBook Pro")

    static func makeModel() -> AppModel {
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        defaults.set(true, forKey: "hasSeenIntro")
        defaults.set(true, forKey: DemoMode.key)
        PairingStore(defaults: defaults).pairedMac = mac
        let scratch = SharedContainer(directory: FileManager.default.temporaryDirectory.appending(path: "screenshots", directoryHint: .isDirectory))
        let demo = MockTransport(library: library, mac: mac, startingAt: songIndex, elapsed: 72,
                                 isPlaying: !ProcessInfo.processInfo.arguments.contains("-screenshotPaused"),
                                 musicConnection: .connected)
        return AppModel(
            transport: DemoCapableTransport(real: UnconfiguredTransport(), demo: demo, startsInDemo: true),
            sessionController: RemoteSessionController(),
            // The real App Group, so the Now Playing extension finds the covers' cache.
            container: SharedContainer.appGroup(),
            defaults: defaults,
            registrar: MockPushTokenRegistrar(container: scratch)
        )
    }

    /// Shows the song in Now Playing once the simulated Mac has sent it.
    static func start(model: AppModel) {
        guard isOn else { return }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            await model.activateNowPlaying()
        }
    }

    /// The demo's songs with made-up catalogue IDs, so Continue Listening
    /// reads as it does for an Apple Music song. Nothing is tapped.
    private static var library: MockLibrary {
        MockLibrary(tracks: MockLibrary.standard.tracks.enumerated().map { offset, track in
            TrackMetadata(id: track.id, title: track.title, artist: track.artist, album: track.album,
                          duration: track.duration, artworkID: track.artworkID, catalogID: String(1_800_000_001 + offset))
        })
    }

    private static var songIndex: Int {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-screenshotSong"), arguments.indices.contains(flag + 1),
              let number = Int(arguments[flag + 1]) else { return 0 }
        return number - 1
    }
}
#endif
