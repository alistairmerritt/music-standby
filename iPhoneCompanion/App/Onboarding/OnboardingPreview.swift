#if DEBUG
import Foundation
import StandByKit

/// Development builds only: any first-run state, for screenshots in the
/// simulator or on a phone, without a real pairing (16 November 2026).
///
///     xcrun simctl launch booted com.alistairmerritt.MusicStandBy -onboardingPreview pair-wrong
///
/// Its settings live in their own defaults suite, so nothing real changes.
@MainActor
struct OnboardingPreview {
    let name: String
    let route: OnboardingRoute
    var facts = OnboardingFacts()
    var macName = "MacBook Pro"
    var macOffline = false
    var macPlaying = false
    var musicConnection: MusicConnection? = .notConnected
    var problem: OnboardingCoordinator.PairingProblem?
    var waitedLong = false
    var blocked = false
    var accessRefused = false
    var canPlayAppleMusic: Bool? = true
    var linkSent = false
    var resumed = false
    var help = false
    var code = ""

    static let suite = "com.alistairmerritt.MusicStandBy.onboardingPreview"

    static let names = ["welcome", "mac", "mac-sent", "pair", "pair-typing", "pair-wrong", "pair-offline", "pair-rate", "approve",
                        "approve-denied", "approve-expired", "play", "play-waited", "play-offline", "playing", "play-blocked", "success",
                        "cl-intro", "cl-intro-nosub", "cl-music", "cl-music-old", "cl-access", "cl-denied", "cl-ready", "resume", "help"]

    static func fromLaunchArguments() -> OnboardingPreview? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let at = arguments.firstIndex(of: "-onboardingPreview"), arguments.indices.contains(at + 1) else { return nil }
        return named(arguments[at + 1])
    }

    static func named(_ name: String) -> OnboardingPreview? {
        var p: OnboardingPreview
        switch name {
        case "welcome": p = .init(name: name, route: .welcome)
        case "mac": p = .init(name: name, route: .macApp)
        case "mac-sent": p = .init(name: name, route: .macApp); p.linkSent = true
        case "pair": p = .init(name: name, route: .pair)
        case "pair-typing": p = .init(name: name, route: .pair); p.code = "482"
        case "pair-wrong": p = .init(name: name, route: .pair); p.problem = .wrongCode
        case "pair-offline": p = .init(name: name, route: .pair); p.problem = .offline
        case "pair-rate": p = .init(name: name, route: .pair); p.problem = .tooManyTries
        case "approve": p = .init(name: name, route: .pair); p.facts.awaitingMacName = "MacBook Pro"
        case "approve-denied": p = .init(name: name, route: .pair); p.problem = .denied(macName: "MacBook Pro")
        case "approve-expired": p = .init(name: name, route: .pair); p.problem = .expired
        case "play", "resume": p = .init(name: name, route: .play); p.facts.paired = true; p.resumed = name == "resume"
        case "play-waited": p = .init(name: name, route: .play); p.facts.paired = true; p.waitedLong = true
        case "play-offline": p = .init(name: name, route: .play); p.facts.paired = true; p.macOffline = true
        case "playing": p = .init(name: name, route: .play); p.facts.paired = true; p.macPlaying = true
        case "play-blocked": p = .init(name: name, route: .play); p.facts.paired = true; p.macPlaying = true; p.blocked = true
        case "success": p = .init(name: name, route: .success); p.facts.paired = true; p.facts.playerShowing = true; p.macPlaying = true
        case "cl-intro": p = .init(name: name, route: .continueIntro)
        case "cl-intro-nosub": p = .init(name: name, route: .continueIntro); p.canPlayAppleMusic = false
        case "cl-music": p = .init(name: name, route: .continueMusic)
        case "cl-music-old": p = .init(name: name, route: .continueMusic); p.musicConnection = nil
        case "cl-access": p = .init(name: name, route: .continueAccess); p.musicConnection = .connected
        case "cl-denied": p = .init(name: name, route: .continueAccess); p.musicConnection = .connected; p.accessRefused = true
        case "cl-ready": p = .init(name: name, route: .continueReady); p.musicConnection = .connected
        case "help": p = .init(name: name, route: .pair); p.help = true
        default: return nil
        }
        if [.continueIntro, .continueMusic, .continueAccess, .continueReady].contains(p.route) {
            p.facts.paired = true; p.facts.playerShowing = true; p.macPlaying = true
        }
        p.facts.musicConnection = p.musicConnection
        return p
    }

    var paired: Bool { facts.paired }

    func apply(to flow: OnboardingCoordinator) {
        flow.setPreviewState(problem: problem, waitedLong: waitedLong, blocked: blocked, accessRefused: accessRefused,
                             canPlayAppleMusic: canPlayAppleMusic, linkSent: linkSent, resumed: resumed, help: help, code: code)
    }

    /// A model to match: unpaired before pairing, otherwise a simulated Mac
    /// called MacBook Pro playing (or not) the demo's Low Sun.
    func makeModel() -> AppModel {
        let defaults = UserDefaults(suiteName: Self.suite) ?? .standard
        defaults.removePersistentDomain(forName: Self.suite)
        defaults.set(true, forKey: "hasSeenIntro")
        defaults.set(false, forKey: "onboarding.finished")
        let mac = PairedMac(id: "preview", name: macName)
        let transport: any PlaybackTransport
        if paired {
            PairingStore(defaults: defaults).pairedMac = mac
            transport = MockTransport(mac: mac, elapsed: 112, isPlaying: macPlaying, musicConnection: musicConnection)
        } else {
            transport = DemoCapableTransport(real: UnconfiguredTransport(), startsInDemo: false)
        }
        let scratch = SharedContainer(directory: FileManager.default.temporaryDirectory.appending(path: "onboarding-preview", directoryHint: .isDirectory))
        return AppModel(transport: transport, sessionController: RemoteSessionController(), container: scratch,
                        defaults: defaults, registrar: MockPushTokenRegistrar(container: scratch))
    }
}
#endif
