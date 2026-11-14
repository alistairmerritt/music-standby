import Foundation
import NowPlaying
import Observation
import StandByKit

/// The app's handle on the system remote session.
@MainActor
@Observable
final class RemoteSessionController: RemoteSessionControlling {
    private typealias Session = RemoteMediaSession<MacPlaybackAttributes>

    private var session: Session?
    private(set) var lastError: String?
    private(set) var lastPrimaryError: String?

    var isActive: Bool { session != nil }
    var isSystemPrimary: Bool { session?.isSystemPrimary ?? false }
    var sessionID: String? { session?.id }

    /// Reuses a session that survived an app restart, otherwise starts one.
    /// Must run while the app is in the foreground for the primary request to count.
    func activate(with attributes: MacPlaybackAttributes) async {
        do {
            let current: Session
            if let existing = try await Session.sessions().first(where: { $0.id == attributes.id }) {
                try await existing.update(attributes)
                current = existing
            } else {
                current = try await Session.start(attributes: attributes)
            }
            session = current
            lastError = nil
        } catch {
            lastError = String(describing: error)
            return
        }
        await requestPrimary()
    }

    /// The system keeps a session after the app quits. A Shortcuts action
    /// that stops showing runs in a fresh launch that hasn't picked it up,
    /// because that happens only once the Mac's state arrives.
    func adoptExisting() async {
        guard session == nil, let existing = try? await Session.sessions().first else { return }
        session = existing
    }

    func publish(_ attributes: MacPlaybackAttributes) async {
        guard let session else { return }
        do {
            try await session.update(attributes)
            lastError = nil
        } catch {
            // The system may have ended it. Drop the handle so the next update or
            // foreground activates again, reusing it if it is still there.
            self.session = nil
            lastError = String(describing: error)
        }
    }

    func deactivate() async {
        guard let session else { return }
        do {
            try await session.end()
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
        self.session = nil
    }

    func requestPrimary() async {
        guard let session else { return }
        do {
            try await session.requestToBecomeSystemPrimary()
            lastPrimaryError = nil
        } catch {
            lastPrimaryError = String(describing: error)
        }
    }

    /// Forwards push-to-start tokens to the registrar for as long as the app runs.
    func observePushToStartTokens(registrar: any PushTokenRegistrar) async {
        if let token = Session.pushToStartToken {
            try? await registrar.registerStartToken(token.hexString)
        }
        for await token in Session.pushToStartTokenUpdates {
            try? await registrar.registerStartToken(token.hexString)
        }
    }
}
