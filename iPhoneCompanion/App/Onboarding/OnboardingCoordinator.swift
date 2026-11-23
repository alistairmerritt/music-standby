import StandByKit
import SwiftUI
import UIKit

/// Runs the first run (V2, 16 November 2026). `Onboarding` in StandByKit
/// decides where the person is; this keeps what the views need on top: the
/// code being typed, pairing problems, the timers, the player check, Apple
/// Music access, and the stored progress.
@MainActor
@Observable
final class OnboardingCoordinator {
    enum PairingProblem: Equatable {
        case wrongCode, offline, tooManyTries, other(String)
        /// These two end the wait for the Mac, and get their own screen.
        case denied(macName: String), expired
    }

    /// Nil while Home shows.
    private(set) var route: OnboardingRoute?
    var code = ""
    private(set) var pairingProblem: PairingProblem?
    private(set) var isPairing = false
    var linkSent = false
    var showingHelp = false
    private(set) var playerShowing = false
    private(set) var playerBlocked = false
    /// The current step has waited long enough to offer help.
    private(set) var waitedLong = false
    private(set) var accessRefused = false
    /// Nil until checked; false means no Apple Music subscription here.
    private(set) var canPlayAppleMusic: Bool?
    /// Opened again from Home, or on a launch part-way through.
    private(set) var resumed = false
    private(set) var appleMusicAccess: AppleMusicAccess

    let progress: OnboardingProgress
    let phoneMusic = SystemMusicPhonePlayer()
    private var pairingTask: Task<Void, Never>?
    private var lastAwaitingMac: String?
    private var activeButNotShownSince: Date?
    #if DEBUG
    let preview: OnboardingPreview?
    #endif

    init(progress: OnboardingProgress, model: AppModel) {
        self.progress = progress
        appleMusicAccess = phoneMusic.access
        #if DEBUG
        preview = OnboardingPreview.fromLaunchArguments()
        if let preview {
            route = preview.route
            preview.apply(to: self)
            return
        }
        #endif
        route = Onboarding.start(progress: progress.snapshot, paired: model.pairedMac != nil, inDemo: model.isDemo)
        resumed = route == .play
    }

    // MARK: Facts

    func facts(for model: AppModel) -> OnboardingFacts {
        #if DEBUG
        if let preview { return preview.facts }
        #endif
        return OnboardingFacts(paired: model.pairedMac != nil && !model.isDemo,
                               awaitingMacName: model.pairingAwaitingMac?.name,
                               playerShowing: playerShowing,
                               musicConnection: model.macMusicConnection,
                               appleMusicAccess: appleMusicAccess)
    }

    func update(_ facts: OnboardingFacts) {
        if let name = facts.awaitingMacName { lastAwaitingMac = name }
        guard let route else { return }
        let next = Onboarding.advance(route, with: facts)
        if next != route { go(next) }
    }

    /// The Mac's name as the person knows it, once there is one.
    func macName(_ model: AppModel) -> String {
        #if DEBUG
        if let preview { return preview.macName }
        #endif
        return model.pairedMac?.name ?? model.pairingAwaitingMac?.name ?? lastAwaitingMac ?? "your Mac"
    }

    func isMacOffline(_ model: AppModel) -> Bool {
        #if DEBUG
        if let preview { return preview.macOffline }
        #endif
        if case .macOffline = model.connection { return true }
        return false
    }

    // MARK: Moving about

    func go(_ next: OnboardingRoute) {
        withAnimation(.smooth(duration: 0.45)) { route = next }
        waitedLong = false
        if next == .success { progress.markPlayerShown() }
    }

    func back() {
        guard let route else { return }
        switch route {
        case .macApp: go(.welcome)
        case .pair: go(.macApp)
        case .continueMusic: go(.continueIntro)
        case .continueAccess: accessRefused = false; go(.continueMusic)
        default: break
        }
    }

    func getStarted(_ model: AppModel) {
        progress.markWelcomeSeen()
        model.finishIntro()
        go(.macApp)
    }

    func exploreDemo(_ model: AppModel) {
        Task { await model.startDemo() }
    }

    /// Home again. Whatever's unfinished shows there as a row.
    func finish() {
        progress.markFinished()
        withAnimation(.smooth) { route = nil }
    }

    /// From Home's rows: carry on with the player, or set up Continue Listening.
    func resume(_ at: OnboardingRoute) {
        resumed = at == .play
        go(at)
    }

    /// After unpairing or leaving the demo: wherever a launch would start.
    func restart(_ model: AppModel) {
        progress.reopen()
        code = ""; pairingProblem = nil; playerShowing = false; playerBlocked = false
        let start = Onboarding.start(progress: progress.snapshot, paired: model.pairedMac != nil, inDemo: model.isDemo)
        withAnimation(.smooth) { route = start }
    }

    func markWaitedLong() { waitedLong = true }

    // MARK: Pairing

    func submitCode(_ model: AppModel) {
        guard code.count == 6, !isPairing else { return }
        pairingProblem = nil
        isPairing = true
        let raw = code
        pairingTask = Task {
            defer { isPairing = false; pairingTask = nil }
            do {
                try await model.pair(rawCode: raw)
            } catch is CancellationError {
                code = ""
            } catch let error as TransportError {
                pairingProblem = problem(for: error)
                code = ""
            } catch {
                pairingProblem = .other(error.localizedDescription)
                code = ""
            }
        }
    }

    func cancelPairing() {
        pairingTask?.cancel()
    }

    /// After a refusal or an expiry: back to typing a new code.
    func tryPairingAgain() {
        pairingProblem = nil
        code = ""
        go(.pair)
    }

    private func problem(for error: TransportError) -> PairingProblem {
        switch error {
        case .pairingRejected: .wrongCode
        case .pairingDenied: .denied(macName: lastAwaitingMac ?? "Your Mac")
        case .pairingExpired: .expired
        case .rateLimited: .tooManyTries
        case .network, .timedOut, .notConnected, .macUnreachable: .offline
        default: .other(error.localizedDescription)
        }
    }

    // MARK: The player

    /// iOS doesn't announce when the session becomes the one on the Lock
    /// Screen, so the play step asks twice a second. Success only once it's
    /// both active and primary; "blocked" after three seconds of active but
    /// not primary, when another app holds the Lock Screen.
    func checkPlayer(_ controller: any RemoteSessionControlling) {
        #if DEBUG
        if preview != nil { return }
        #endif
        let active = controller.isActive, primary = controller.isSystemPrimary
        if active && primary {
            playerShowing = true
            playerBlocked = false
            activeButNotShownSince = nil
        } else if active {
            let since = activeButNotShownSince ?? Date()
            activeButNotShownSince = since
            playerBlocked = Date().timeIntervalSince(since) > 3
        } else {
            activeButNotShownSince = nil
            playerBlocked = false
        }
    }

    func showOnLockScreen(_ model: AppModel) async {
        await model.activateNowPlaying()
        await model.sessionController.requestPrimary()
    }

    // MARK: Continue Listening

    func checkAppleMusic() async {
        #if DEBUG
        if preview != nil { return }
        #endif
        appleMusicAccess = phoneMusic.access
        if canPlayAppleMusic == nil { canPlayAppleMusic = await phoneMusic.canPlayCatalog() }
    }

    func askForAppleMusic() async {
        let allowed = await phoneMusic.requestAccess()
        appleMusicAccess = phoneMusic.access
        accessRefused = !allowed
    }

    func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }

    #if DEBUG
    /// The preview's fixed state, set before anything draws.
    func setPreviewState(problem: PairingProblem?, waitedLong: Bool, blocked: Bool, accessRefused: Bool, canPlayAppleMusic: Bool?, linkSent: Bool, resumed: Bool, help: Bool, code: String) {
        pairingProblem = problem
        self.waitedLong = waitedLong
        playerBlocked = blocked
        self.accessRefused = accessRefused
        self.canPlayAppleMusic = canPlayAppleMusic
        self.linkSent = linkSent
        self.resumed = resumed
        showingHelp = help
        self.code = code
    }
    #endif
}
