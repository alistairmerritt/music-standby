import Foundation

/// Continue from iPhone, asked for at the Mac: the phone's side
/// (docs/relay/API-v1.md §14). The relay wakes the app with a background
/// push, or, when that gets no answer, shows a notification whose tap does
/// it. Either way this runs Continue on Mac (`Handover.sendBackToMac`) from
/// the relay's state, as the Shortcuts action does, and reports each step to
/// the relay, which passes it to the Mac. Added 12 November 2026.
@MainActor
public final class HandBackResponder {
    public enum Trigger: Sendable {
        /// The background push. Ignored after the request's `expiresAt`:
        /// music moving minutes after the click would be a surprise.
        case wake
        /// A tap on the notification: the tap is the request, however late.
        case tap
    }

    private let makeRemote: @MainActor () throws -> MacRemote
    private let report: @Sendable (HandBackStatusReport) async throws -> Void
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private var inProgress: Set<UUID> = []
    static let handledKey = "handBackHandled"
    /// The newest request ids acted on, so a late wake and a tap for one
    /// request don't hand back twice, even across a relaunch.
    static let handledLimit = 20

    public init(
        defaults: UserDefaults,
        makeRemote: @escaping @MainActor () throws -> MacRemote,
        report: @escaping @Sendable (HandBackStatusReport) async throws -> Void,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.makeRemote = makeRemote
        self.report = report
        self.now = now
    }

    /// The request in a push's payload, or nil when the push isn't a hand-back.
    public nonisolated static func request(from userInfo: [AnyHashable: Any]) -> HandBackRequest? {
        guard let body = userInfo[HandBackRequest.payloadKey], JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        return try? StandByWire.makeDecoder().decode(HandBackRequest.self, from: data)
    }

    /// Hands the phone's music back to the Mac. Returns the final status, or
    /// nil when the request was ignored: already handled, or a wake too late.
    @discardableResult
    public func respond(to request: HandBackRequest, via trigger: Trigger, player: any PhoneMusicPlaying) async -> HandBackStatus? {
        let id = request.requestID
        guard !handled.contains(id), !inProgress.contains(id) else { return nil }
        if trigger == .wake, now() > request.expiresAt { return nil }
        inProgress.insert(id)
        defer { inProgress.remove(id) }
        remember(id)
        await send(.working, for: id)
        let status: HandBackStatus
        do {
            let remote = try makeRemote()
            try await remote.read()
            status = Self.status(for: await remote.handover().sendBackToMac(with: player))
        } catch {
            status = .failed
        }
        await send(status, for: id)
        return status
    }

    static func status(for outcome: SendBackOutcome) -> HandBackStatus {
        switch outcome {
        case .sentBack: .done
        case .nothingPlayingHere: .nothingPlaying
        case .notInMacQueue: .notInQueue
        case .macRefused, .macDidNotStart: .failed
        }
    }

    /// A report that doesn't arrive costs only the Mac's progress line; the
    /// Mac's own state still shows the music arriving.
    private func send(_ status: HandBackStatus, for id: UUID) async {
        try? await report(HandBackStatusReport(requestID: id, status: status))
    }

    private var handled: [UUID] {
        (defaults.stringArray(forKey: Self.handledKey) ?? []).compactMap(UUID.init(uuidString:))
    }

    private func remember(_ id: UUID) {
        let ids = (handled + [id]).suffix(Self.handledLimit).map(\.uuidString)
        defaults.set(Array(ids), forKey: Self.handledKey)
    }
}
