import ActivityKit
import Foundation
import StandByKit

/// The app's side of the Live Activity card (experiment, 23 November 2026).
///
/// - Sends the push-to-start token to the relay, so the relay can start the
///   card when the Mac plays after a break (the moment iOS has probably given
///   the Lock Screen to Apple Music).
/// - Follows each card iOS starts from that push: sends its update token,
///   and tells the relay when it's gone.
/// - Ends the card once the app has the Mac's player back, so the two don't
///   show together.
///
/// iOS starts the card and then wakes the app in the background to collect
/// the token ("…wakes up your app, and grants it background runtime"), so
/// `start()` runs on every launch, background ones included.
@MainActor
final class LiveActivityController {
    static let shared = LiveActivityController()

    private typealias Card = Activity<MacPlaybackActivityAttributes>
    private var client: () -> RelayClient? = { nil }
    private var started = false
    /// Cards already being followed, by iOS's id.
    private var following: Set<String> = []

    func start(client: @escaping () -> RelayClient?) {
        guard !started else { return }
        started = true
        self.client = client
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            LockScreenRecord.add("Live Activities are off for Second Chair in Settings, so the relay will send the reminder")
            return
        }
        Task { await observeStartTokens() }
        Task { await observeNewCards() }
        for card in Card.activities { follow(card) }
    }

    /// The pairing changed: its relay record has no token yet.
    func uploadStartToken() {
        guard let token = Card.pushToStartToken else { return }
        Task { try? await client()?.registerActivityStartToken(token.hexString) }
    }

    /// The Mac's player is back on screen, so the card is no longer needed.
    func endAll(because reason: String) {
        let cards = Card.activities
        guard !cards.isEmpty else { return }
        LockScreenRecord.add("Live Activity: ended \(cards.count == 1 ? "the card" : "\(cards.count) cards") (\(reason))")
        for card in cards {
            let id = card.attributes.activityID
            Task {
                await card.end(nil, dismissalPolicy: .immediate)
                try? await client()?.removeActivityToken(activityID: id)
            }
        }
    }

    private func observeStartTokens() async {
        if let token = Card.pushToStartToken { await sendStartToken(token) }
        for await token in Card.pushToStartTokenUpdates { await sendStartToken(token) }
    }

    private func sendStartToken(_ token: Data) async {
        do {
            try await client()?.registerActivityStartToken(token.hexString)
        } catch {
            LockScreenRecord.add("Live Activity: couldn’t send the start token (\(error.localizedDescription))")
        }
    }

    private func observeNewCards() async {
        for await card in Card.activityUpdates { follow(card) }
    }

    private func follow(_ card: Card) {
        guard following.insert(card.id).inserted else { return }
        let id = card.attributes.activityID
        LockScreenRecord.add("Live Activity: following the card for “\(card.content.state.title)” (\(card.activityState))")
        Task {
            for await token in card.pushTokenUpdates {
                do {
                    try await client()?.registerActivityToken(token.hexString, activityID: id)
                    LockScreenRecord.add("Live Activity: sent the card’s update token")
                } catch {
                    LockScreenRecord.add("Live Activity: couldn’t send the card’s update token (\(error.localizedDescription))")
                }
            }
        }
        Task {
            for await state in card.activityStateUpdates {
                switch state {
                case .dismissed, .ended:
                    LockScreenRecord.add("Live Activity: the card \(state == .dismissed ? "was swiped away" : "ended")")
                    try? await client()?.removeActivityToken(activityID: id)
                    following.remove(card.id)
                    return
                default:
                    break
                }
            }
        }
    }

    #if DEBUG
    /// `-liveActivityDemo`: a card with the demo's Low Sun, started here, to
    /// see and screenshot it in the Simulator or on a development build.
    func startDemoIfAsked() {
        guard ProcessInfo.processInfo.arguments.contains("-liveActivityDemo") else { return }
        let playing = !ProcessInfo.processInfo.arguments.contains("-liveActivityPaused")
        let state = MacPlaybackActivityAttributes.ContentState(
            title: "Low Sun", artist: "Drift Hotel", album: "Golden Hour", artworkID: "mock-art-low-sun",
            isPlaying: playing, elapsed: 75, capturedAt: Date().timeIntervalSince1970, duration: 214, canGoNext: true)
        do {
            _ = try Card.request(attributes: MacPlaybackActivityAttributes(activityID: "demo", macName: "MacBook Pro"),
                                 content: ActivityContent(state: state, staleDate: nil))
        } catch {
            LockScreenRecord.add("Live Activity demo didn’t start: \(error.localizedDescription)")
        }
    }
    #endif
}
