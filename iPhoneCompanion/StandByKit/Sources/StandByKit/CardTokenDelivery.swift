import Foundation
import StandByProtocol

/// What became of a Live Activity card's update token sent to the relay.
public enum CardTokenDelivery: Equatable, Sendable {
    case sent
    /// The relay didn't start this card, or has started another since, so it
    /// will never update it: a second card for one song, frozen and without
    /// artwork, as on 26 November 2026. The app ends it.
    case notTheRelays
    case failed(String)

    /// How long before asking a second time. A relay before 26 November 2026
    /// recorded a card only once APNs had answered its start, so the token of
    /// a card it had just started could arrive first and be refused.
    public static let retryAfter: Duration = .seconds(3)

    /// Sends the token with `send`. Refused as not the relay's card
    /// (`activity_mismatch`), it waits and asks once more before believing it.
    public static func deliver(_ send: @Sendable () async throws -> Void,
                               wait: @Sendable () async -> Void = { try? await Task.sleep(for: retryAfter) }) async -> CardTokenDelivery {
        for attempt in 1...2 {
            do {
                try await send()
                return .sent
            } catch TransportError.commandRejected(.activityMismatch) {
                if attempt == 2 { break }
                await wait()
            } catch {
                return .failed(error.localizedDescription)
            }
        }
        return .notTheRelays
    }
}
