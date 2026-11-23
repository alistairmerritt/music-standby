import Foundation

/// The first run, V2 (docs/design/onboarding, 16 November 2026): a welcome,
/// then one scene that changes as setup goes, a success confirmed by iOS,
/// and Continue Listening as its own moment. These types decide where the
/// person is; the views only draw it.
public enum OnboardingRoute: String, Equatable, Sendable, CaseIterable {
    case welcome
    case macApp
    case pair
    case play
    case success
    case continueIntro
    case continueMusic
    case continueAccess
    case continueReady
}

/// What the devices report, as far as the first run cares.
public struct OnboardingFacts: Equatable, Sendable {
    public var paired: Bool
    /// The Mac a pairing is waiting on, once the code has been accepted.
    public var awaitingMacName: String?
    /// iOS has the Lock Screen player active, and showing (primary).
    public var playerShowing: Bool
    public var musicConnection: MusicConnection?
    public var appleMusicAccess: AppleMusicAccess

    public init(paired: Bool = false, awaitingMacName: String? = nil, playerShowing: Bool = false,
                musicConnection: MusicConnection? = nil, appleMusicAccess: AppleMusicAccess = .notDetermined) {
        self.paired = paired
        self.awaitingMacName = awaitingMacName
        self.playerShowing = playerShowing
        self.musicConnection = musicConnection
        self.appleMusicAccess = appleMusicAccess
    }
}

public enum Onboarding {
    /// Where the facts take the person from here. Only ever forward: a
    /// success stays on screen until they move on, whatever happens next.
    public static func advance(_ route: OnboardingRoute, with facts: OnboardingFacts) -> OnboardingRoute {
        switch route {
        case .macApp, .pair:
            guard facts.paired else { return route }
            return facts.playerShowing ? .success : .play
        case .play:
            return facts.playerShowing ? .success : .play
        case .continueMusic:
            guard facts.musicConnection == .connected else { return route }
            return facts.appleMusicAccess == .allowed ? .continueReady : .continueAccess
        case .continueAccess:
            return facts.appleMusicAccess == .allowed ? .continueReady : .continueAccess
        case .welcome, .success, .continueIntro, .continueReady:
            return route
        }
    }

    /// Where a launch starts, or nil for Home.
    public static func start(progress: OnboardingProgress.Snapshot, paired: Bool, inDemo: Bool) -> OnboardingRoute? {
        if inDemo { return nil }
        if !paired {
            if !progress.seenWelcome { return .welcome }
            // Someone who has had the player working before knows the Mac side.
            return progress.playerHasShown ? .pair : .macApp
        }
        if progress.finished { return nil }
        return progress.playerHasShown ? .continueIntro : .play
    }

    /// The setup steps, for the progress bar and its labels.
    public static func setupStep(of route: OnboardingRoute) -> (index: Int, of: Int)? {
        switch route {
        case .macApp: (1, 3)
        case .pair: (2, 3)
        case .play: (3, 3)
        case .continueMusic: (1, 2)
        case .continueAccess: (2, 2)
        default: nil
        }
    }
}

/// How far the first run has got, kept in the App Group.
public final class OnboardingProgress: @unchecked Sendable {
    public struct Snapshot: Equatable, Sendable {
        public var seenWelcome: Bool
        public var playerHasShown: Bool
        public var finished: Bool

        public init(seenWelcome: Bool = false, playerHasShown: Bool = false, finished: Bool = false) {
            self.seenWelcome = seenWelcome
            self.playerHasShown = playerHasShown
            self.finished = finished
        }
    }

    /// Shared with the original intro, so a phone that saw it doesn't see the welcome again.
    static let seenWelcomeKey = "hasSeenIntro"
    static let playerShownKey = "onboarding.playerHasShown"
    static let finishedKey = "onboarding.finished"

    private let defaults: UserDefaults

    /// A phone paired before this first run existed has done all of it.
    public init(defaults: UserDefaults, alreadyPaired: Bool) {
        self.defaults = defaults
        if alreadyPaired, defaults.object(forKey: Self.finishedKey) == nil, defaults.bool(forKey: Self.seenWelcomeKey) {
            defaults.set(true, forKey: Self.playerShownKey)
            defaults.set(true, forKey: Self.finishedKey)
        }
    }

    public var snapshot: Snapshot {
        Snapshot(seenWelcome: defaults.bool(forKey: Self.seenWelcomeKey),
                 playerHasShown: defaults.bool(forKey: Self.playerShownKey),
                 finished: defaults.bool(forKey: Self.finishedKey))
    }

    /// Also writes "not finished", so a phone that quits mid-setup isn't
    /// mistaken for one paired before this first run existed.
    public func markWelcomeSeen() {
        defaults.set(true, forKey: Self.seenWelcomeKey)
        if defaults.object(forKey: Self.finishedKey) == nil { defaults.set(false, forKey: Self.finishedKey) }
    }
    public func markPlayerShown() { defaults.set(true, forKey: Self.playerShownKey) }
    public func markFinished() { defaults.set(true, forKey: Self.finishedKey) }
    /// After unpairing: the next pairing goes through the first run again, from pairing.
    public func reopen() { defaults.set(false, forKey: Self.finishedKey) }
}
