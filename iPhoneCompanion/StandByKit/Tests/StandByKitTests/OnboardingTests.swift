import Foundation
import Testing
@testable import StandByKit

/// The first run, V2 (16 November 2026).
struct OnboardingFlowTests {
    @Test func pairingMovesSetupOnToPlayingAndNotBeforeTheMacAllows() {
        var facts = OnboardingFacts()
        #expect(Onboarding.advance(.pair, with: facts) == .pair)
        facts.awaitingMacName = "MacBook Pro"
        #expect(Onboarding.advance(.pair, with: facts) == .pair, "the approval wait is drawn by the pair step itself")
        facts.paired = true
        #expect(Onboarding.advance(.pair, with: facts) == .play)
        #expect(Onboarding.advance(.macApp, with: facts) == .play, "a code typed straight away skips the Mac step")
    }

    @Test func successNeedsThePlayerShowingAndThenStays() {
        var facts = OnboardingFacts(paired: true)
        #expect(Onboarding.advance(.play, with: facts) == .play)
        facts.playerShowing = true
        #expect(Onboarding.advance(.play, with: facts) == .success)
        facts.playerShowing = false
        #expect(Onboarding.advance(.success, with: facts) == .success, "never back to waiting once it has worked")
    }

    @Test func continueListeningTicksItsOwnSteps() {
        var facts = OnboardingFacts(paired: true, playerShowing: true)
        #expect(Onboarding.advance(.continueMusic, with: facts) == .continueMusic)
        facts.musicConnection = .notConnected
        #expect(Onboarding.advance(.continueMusic, with: facts) == .continueMusic)
        facts.musicConnection = .connected
        #expect(Onboarding.advance(.continueMusic, with: facts) == .continueAccess)
        facts.appleMusicAccess = .allowed
        #expect(Onboarding.advance(.continueMusic, with: facts) == .continueReady, "access allowed earlier skips its step")
        #expect(Onboarding.advance(.continueAccess, with: facts) == .continueReady)
        facts.appleMusicAccess = .denied
        #expect(Onboarding.advance(.continueAccess, with: facts) == .continueAccess)
    }

    @Test func launchesStartWhereThePersonLeftOff() {
        typealias P = OnboardingProgress.Snapshot
        #expect(Onboarding.start(progress: P(), paired: false, inDemo: false) == .welcome)
        #expect(Onboarding.start(progress: P(seenWelcome: true), paired: false, inDemo: false) == .macApp)
        #expect(Onboarding.start(progress: P(seenWelcome: true), paired: true, inDemo: false) == .play)
        #expect(Onboarding.start(progress: P(seenWelcome: true, playerHasShown: true), paired: true, inDemo: false) == .continueIntro)
        #expect(Onboarding.start(progress: P(seenWelcome: true, playerHasShown: true, finished: true), paired: true, inDemo: false) == nil)
        #expect(Onboarding.start(progress: P(seenWelcome: true, playerHasShown: true, finished: true), paired: false, inDemo: false) == .pair,
                "after unpairing, someone who has done it before goes straight to the code")
        #expect(Onboarding.start(progress: P(), paired: true, inDemo: true) == nil)
    }

    @Test func progressBarsCountTheSetupSteps() {
        #expect(Onboarding.setupStep(of: .macApp)! == (1, 3))
        #expect(Onboarding.setupStep(of: .play)! == (3, 3))
        #expect(Onboarding.setupStep(of: .continueAccess)! == (2, 2))
        #expect(Onboarding.setupStep(of: .welcome) == nil)
    }
}

struct OnboardingProgressTests {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "test-\(UUID().uuidString)")! }

    @Test func aPhonePairedBeforeTheFirstRunExistedHasFinishedIt() {
        let d = defaults()
        d.set(true, forKey: "hasSeenIntro")
        let progress = OnboardingProgress(defaults: d, alreadyPaired: true)
        #expect(progress.snapshot == .init(seenWelcome: true, playerHasShown: true, finished: true))
    }

    @Test func aNewPhoneStartsAtTheBeginningAndRemembersEachStep() {
        let d = defaults()
        let progress = OnboardingProgress(defaults: d, alreadyPaired: false)
        #expect(progress.snapshot == .init())
        progress.markWelcomeSeen(); progress.markPlayerShown(); progress.markFinished()
        #expect(OnboardingProgress(defaults: d, alreadyPaired: true).snapshot == .init(seenWelcome: true, playerHasShown: true, finished: true))
        progress.reopen()
        #expect(progress.snapshot.finished == false)
    }

    @Test func aFirstRunInProgressIsntMistakenForAnOldPairing() {
        let d = defaults()
        let progress = OnboardingProgress(defaults: d, alreadyPaired: false)
        progress.markWelcomeSeen()
        // Paired, and the app restarts before the player has shown.
        #expect(OnboardingProgress(defaults: d, alreadyPaired: true).snapshot == .init(seenWelcome: true))
    }
}

@MainActor
struct OnboardingModelTests {
    @Test func pairingTurnsShowingOnSoTheFirstSongShowsItself() async throws {
        let h = Harness(paired: false, nowPlayingEnabled: false)
        let task = await h.run()
        defer { task.cancel() }
        try await h.model.pair(rawCode: "123456")
        #expect(h.model.isNowPlayingEnabled)
        await h.transport.emit(.connection(.connected(macName: "Studio Mac")))
        await h.transport.emit(.playback(message()))
        await eventually("the first song activates the player") { !h.controller.activations.isEmpty }
    }

    @Test func theMacsSongIsKnownBeforeAnySession() async {
        let h = Harness(paired: true, relayNamesSessions: true)
        let task = await h.run()
        defer { task.cancel() }
        await h.transport.emit(.connection(.connected(macName: "Studio Mac")))
        await h.transport.emit(.playback(message(state: .paused)))
        await eventually("the paused song arrives") { h.model.macTrack != nil }
        #expect(h.model.macIsPlaying == false)
        #expect(h.model.attributes == nil, "no session yet: the relay names one only when the Mac plays")
        await h.transport.emit(.playback(message(revision: 2, state: .playing)))
        await eventually("playing") { h.model.macIsPlaying }
    }
}
