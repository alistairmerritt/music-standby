#if DEBUG
import Foundation
import Observation
import StandByKit
import UIKit

/// Development builds only: the demo's songs on this phone, laid out as a
/// paired Mac's, for App Store screenshots, without unpairing the real Mac
/// (16 November 2026).
///
///     xcrun devicectl device process launch --device <udid> --terminate-existing \
///         com.alistairmerritt.MusicStandBy -- -screenshotDemo [-screenshotSong N] [-screenshotAt S] [-screenshotPaused] [-screenshotIntro]
///
/// `N` is 1 to 6, in `MockLibrary.standard`'s order. The song starts `S` seconds in (1:12 by default)
/// and shows in Now Playing straight away. The interface stays portrait,
/// even on a charger on its side. Settings live in their own defaults suite
/// and the Keychain is never read, so the real pairing is untouched; push
/// tokens go nowhere. To go back, launch without the switch and pass
/// `-showNowPlaying`. Lock Screen controls do nothing meanwhile: the
/// extension still holds the real pairing.
@MainActor
enum ScreenshotMode {
    static var isOn: Bool { ProcessInfo.processInfo.arguments.contains("-screenshotDemo") }

    /// `-screenshotNowPlaying on`: Home's Lock Screen section as if the
    /// player had a session (the simulator can't start one).
    static var nowPlayingState: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let at = arguments.firstIndex(of: "-screenshotNowPlaying"), arguments.count > at + 1 else { return nil }
        return arguments[at + 1]
    }

    /// `-screenshotOnIPhone`: Home as if Apple Music here played the Mac's
    /// song, as after Continue on iPhone. Use with `-screenshotPaused`. The
    /// demo's Continue buttons change it, as a real hand-over would.
    static var iPhonePlaying: Bool { DemoHandover.shared.phonePlaying }

    /// `-screenshotScroll ID`: Home scrolls to that section (`continueListening`, `lockScreen`).
    static var scrollTarget: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let at = arguments.firstIndex(of: "-screenshotScroll"), arguments.count > at + 1 else { return nil }
        return arguments[at + 1]
    }

    static let suite = "com.alistairmerritt.MusicStandBy.screenshots"
    private static let mac = PairedMac(id: DemoMode.mac.id, name: "MacBook Pro")

    static func makeModel() -> AppModel {
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        // -screenshotIntro: the first-launch screen, which otherwise shows once.
        defaults.set(!showsIntro, forKey: "hasSeenIntro")
        defaults.set(true, forKey: DemoMode.key)
        PairingStore(defaults: defaults).pairedMac = mac
        let scratch = SharedContainer(directory: FileManager.default.temporaryDirectory.appending(path: "screenshots", directoryHint: .isDirectory))
        let demo = MockTransport(library: library, mac: mac, startingAt: songIndex, elapsed: number(after: "-screenshotAt") ?? 72,
                                 isPlaying: !ProcessInfo.processInfo.arguments.contains("-screenshotPaused"),
                                 musicConnection: .connected,
                                 // Above any earlier launch's, so the Lock Screen takes this one.
                                 revision: UInt64(Date().timeIntervalSince1970))
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
        guard isOn, !showsIntro else { return }
        DemoHandover.shared.startLoopIfAsked()
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            // A fresh session, so nothing of the last launch's lingers.
            await model.stopNowPlaying()
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

    private static var showsIntro: Bool { ProcessInfo.processInfo.arguments.contains("-screenshotIntro") }

    private static var songIndex: Int {
        number(after: "-screenshotSong").map { Int($0) - 1 } ?? 0
    }

    private static func number(after flag: String) -> Double? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let at = arguments.firstIndex(of: flag), arguments.indices.contains(at + 1) else { return nil }
        return Double(arguments[at + 1])
    }
}

/// Development builds' screenshots: a pretend hand-over, so Home's motion can
/// be recorded in the simulator, which has no Apple Music (23 November 2026).
/// `-motionDemo` hands over to the iPhone and back on a loop by itself.
@MainActor
@Observable
final class DemoHandover {
    static let shared = DemoHandover()

    var phonePlaying = ProcessInfo.processInfo.arguments.contains("-screenshotOnIPhone")
    /// Goes up for each automatic hand-over; `autoDirection` says which way.
    private(set) var autoRuns = 0
    private(set) var autoDirection: HandoffDirection = .toPhone

    /// About as long as a real hand-over takes, then the music has moved.
    func run(_ direction: HandoffDirection, model: AppModel) async -> (text: String, isFailure: Bool)? {
        try? await Task.sleep(for: .seconds(1.8))
        switch direction {
        case .toPhone:
            await model.send(.pause)
            phonePlaying = true
        case .toMac:
            phonePlaying = false
            await model.send(.play)
        }
        return nil
    }

    func startLoopIfAsked() {
        guard ProcessInfo.processInfo.arguments.contains("-motionDemo") else { return }
        Task {
            try? await Task.sleep(for: .seconds(3))
            while !Task.isCancelled {
                autoDirection = phonePlaying ? .toMac : .toPhone
                autoRuns += 1
                try? await Task.sleep(for: .seconds(7))
            }
        }
    }
}

#endif
