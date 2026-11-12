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
    /// Takes hold of a session the system kept from an earlier run of the
    /// app, without changing it, so it can be ended. Does nothing while a
    /// session is held.
    func adoptExisting() async
}

extension RemoteSessionControlling {
    public func adoptExisting() async {}
}

/// When a Now Playing session should end.
///
/// Music stopping or quitting on the Mac doesn't end it: the session stays,
/// showing the last track paused, because iOS shows only a session the app
/// asked for while open. It ends when the user stops showing it, unpairs, or
/// the relay has no session. A dropped socket is waited out.
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

    public func decision(from previous: ConnectionState, to next: ConnectionState) -> Decision {
        switch next {
        case .connected, .macOffline:
            // The relay answered, and it owns the session's lifetime from here.
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
