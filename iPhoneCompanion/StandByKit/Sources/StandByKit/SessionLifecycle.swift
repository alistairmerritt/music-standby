import Foundation

/// The app's handle on the system Now Playing session. The app target implements
/// it over `NowPlaying`; tests use a double.
@MainActor
public protocol RemoteSessionControlling: AnyObject {
    var isActive: Bool { get }
    var isSystemPrimary: Bool { get }
    var sessionID: String? { get }
    /// The last failure to start or update the session. Nil once one succeeds.
    var lastError: String? { get }
    /// The last refusal of the primary slot. Separate because a session the
    /// system won't promote is still a working session.
    var lastPrimaryError: String? { get }

    func activate(with attributes: MacPlaybackAttributes) async
    func publish(_ attributes: MacPlaybackAttributes) async
    func deactivate() async
    func requestPrimary() async
    func observePushToStartTokens(registrar: any PushTokenRegistrar) async
}

/// When a Now Playing session should end.
///
/// The rule is to end on what is known and wait out what is only suspected. A
/// paused song and a dropped socket are both ordinary, and neither says the
/// music has finished.
public struct SessionLifecyclePolicy: Equatable, Sendable {
    /// How long a lost link may last before the session is treated as dead.
    /// Matches the relay proposal's 60 s. Chosen by judgement, not measured.
    public var reconnectGrace: TimeInterval

    public init(reconnectGrace: TimeInterval = 60) {
        self.reconnectGrace = reconnectGrace
    }

    public enum Decision: Equatable, Sendable {
        case keep
        case startGrace
        case cancelGrace
        case end(SessionEndReason)
    }

    /// `paused` and `error` keep the session. `stopped`, `not_running` and
    /// `automation_denied` are the Mac confirming playback is over.
    public func endsSession(_ state: PlaybackState) -> Bool {
        !state.continuesSession
    }

    public func decision(from previous: ConnectionState, to next: ConnectionState) -> Decision {
        switch next {
        case .connected:
            return .cancelGrace
        case .connecting:
            return .keep
        case .reconnecting, .failed:
            // Already counting down from the first failure: don't restart the clock.
            switch previous {
            case .reconnecting, .failed: return .keep
            default: return .startGrace
            }
        case .disconnected:
            return previous == .disconnected ? .keep : .end(.macDisconnected)
        }
    }
}
