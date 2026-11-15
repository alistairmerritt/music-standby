import Foundation

/// Apple Music access on this phone, for `ContinueListeningStatus`.
public enum AppleMusicAccess: Equatable, Sendable {
    case allowed, notDetermined, denied
}

/// What the iPhone app says about Continue Listening beside the Mac's status
/// (16 November 2026). Before, Continue Listening simply didn't appear when
/// it couldn't work, with nothing saying why.
public enum ContinueListeningStatus: Equatable, Sendable {
    case ready
    /// The Mac isn't connected to Music as a remote, so it sends no
    /// catalogue IDs or Up Next.
    case setUpOnMac
    /// Music has forgotten the Mac's pairing.
    case reconnectOnMac
    /// Second Chair may not use Apple Music on this phone yet.
    case allowAppleMusic(canAsk: Bool)
    /// This phone can't play from the Apple Music catalogue: no subscription.
    case needsAppleMusic

    /// The Mac first, since Continue on iPhone can't start without it; then
    /// this phone. Nil when there's nothing to say: no word from the Mac yet
    /// (or one too old to report it) and nothing wrong here. `canPlayCatalog`
    /// is nil until known.
    public static func assess(mac: MusicConnection?, appleMusicAccess: AppleMusicAccess, canPlayCatalog: Bool?) -> ContinueListeningStatus? {
        switch mac {
        case .notConnected?: return .setUpOnMac
        case .forgotten?: return .reconnectOnMac
        default: break
        }
        switch appleMusicAccess {
        case .notDetermined: return .allowAppleMusic(canAsk: true)
        case .denied: return .allowAppleMusic(canAsk: false)
        case .allowed: break
        }
        if canPlayCatalog == false { return .needsAppleMusic }
        return mac == .connected ? .ready : nil
    }
}
