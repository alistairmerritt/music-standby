import ActivityKit
import Foundation
import Observation
import StandByKit
import UIKit

/// The app's side of the Live Activity card (experiment, 23 November 2026).
///
/// - Sends the push-to-start token to the relay, so the relay can start the
///   card when the Mac plays after a break (the moment iOS has probably given
///   the Lock Screen to Apple Music).
/// - Follows each card iOS starts from that push: sends its update token,
///   and tells the relay when it's gone.
/// - Ends the card once the app has the Mac's player back, so the two don't
///   show together (Player Display: Automatic).
/// - Switches Player Display, and with Live Activity chosen, asks the relay
///   for the card when the app opens with none showing (24 November 2026).
///
/// iOS starts the card and then wakes the app in the background to collect
/// the token ("…wakes up your app, and grants it background runtime"), so
/// `start()` runs on every launch, background ones included.
@MainActor
final class LiveActivityController {
    static let shared = LiveActivityController()

    private typealias Card = Activity<MacPlaybackActivityAttributes>
    private var client: () -> RelayClient? = { nil }
    private weak var model: AppModel?
    private var isShowing: Bool { model?.isNowPlayingEnabled ?? true }
    private var started = false
    /// What the relay was last told: nil until the first sync.
    private var relayHasToken: Bool?

    static var defaults: UserDefaults { UserDefaults(suiteName: AppGroup.identifier) ?? .standard }
    /// Settings' Player Display.
    static var display: PlayerDisplay { PlayerDisplay.current(in: defaults) }
    /// iOS's own switch: Settings › Second Chair › Live Activities.
    static var systemAllows: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    /// Whether the relay should start the card: Player Display uses it,
    /// showing is on (Stop Showing stops the card too), and iOS allows it.
    private var wanted: Bool { Self.display.usesLiveActivity && isShowing && Self.systemAllows }
    /// Cards already being followed, by iOS's id.
    private var following: Set<String> = []

    func start(client: @escaping () -> RelayClient?, model: AppModel) {
        guard !started else { return }
        started = true
        self.client = client
        self.model = model
        if !Self.systemAllows {
            LockScreenRecord.add("Live Activities are off for Second Chair in Settings, so the relay will send the reminder")
        }
        Task { await observeStartTokens() }
        Task { await observeNewCards() }
        for card in Card.activities { follow(card) }
        watchShowing(model)
        sync()
    }

    /// Stop Showing (from Settings or Shortcuts) stops the card; showing again restarts it.
    private func watchShowing(_ model: AppModel) {
        withObservationTracking {
            _ = model.isNowPlayingEnabled
        } onChange: { [weak self, weak model] in
            Task { @MainActor in
                guard let self, let model else { return }
                self.sync()
                self.watchShowing(model)
            }
        }
    }

    /// The pairing changed: its relay record has no token yet.
    func uploadStartToken() {
        relayHasToken = nil
        sync()
    }

    /// Tells the relay whether to start the card, after the setting, showing
    /// or the pairing changed. Turned off, any card on screen goes too.
    func sync() {
        let wanted = wanted
        guard wanted != relayHasToken else { return }
        relayHasToken = wanted
        if wanted {
            guard let token = Card.pushToStartToken else { return }   // sent when iOS gives it
            Task { await sendStartToken(token) }
        } else {
            LockScreenRecord.add("Live Activity: the card is off (\(Self.display.usesLiveActivity ? (isShowing ? "Live Activities are off in Settings" : "Stop Showing") : "Player Display is Now Playing")); the relay sends the reminder instead")
            Task { try? await client()?.removeActivityStartToken() }
            endAll(because: "the card was turned off")
        }
    }

    /// The Mac's player is back on screen, so the card is no longer needed.
    func endAll(because reason: String) {
        // The development builds' test card stays until it's swiped away.
        let cards = Card.activities.filter { $0.attributes.activityID != "demo" }
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

    // MARK: Player Display (24 November 2026)

    /// Settings' Player Display was changed. Runs with the app open, the only
    /// time iOS lets it bring Now Playing back. The Mac's music isn't touched.
    /// - Returns: what went wrong, to show under the choices, or nil.
    @discardableResult
    func setDisplay(_ display: PlayerDisplay) async -> String? {
        let before = Self.display
        guard display != before, let model else { return nil }
        display.save(in: Self.defaults)
        LockScreenRecord.add("Player Display: \(before.title) → \(display.title)")
        guard isShowing else { sync(); return nil }   // Stop Showing: nothing shows until it's turned back on
        switch display {
        case .liveActivity:
            // The relay ends the Now Playing session and push-starts a hidden
            // one (it still caches the card's artwork), with the card.
            await model.endNowPlayingForLiveActivity()
            sync()
            guard Self.systemAllows else { return "Live Activities are turned off for Second Chair in Settings." }
            guard model.macTrack != nil else { return nil }   // the card comes when the Mac next plays after a break, or when you open Second Chair
            return await showCard(fresh: true) ? nil : "Couldn’t show the Live Activity. Try again in a moment."
        case .nowPlaying, .automatic:
            // Now Playing first; the card goes once iOS has taken the request.
            if !before.usesNowPlaying {
                await waitForRelaySession(model)
                await model.activateNowPlaying()
                if model.sessionController.lastPrimaryError == nil {
                    endAll(because: "Player Display is \(display.title), and Now Playing is back")
                }
            }
            sync()   // Now Playing alone: the relay stops starting the card, and any card ends
            return nil
        }
    }

    /// Coming back from Live Activity, the relay may have started a new Now
    /// Playing session (a new ID) moments ago. Showing the player before the
    /// app has that ID started one under the old ID, which nothing updated:
    /// StandBy stuck on an old song (24 November 2026). So it waits, up to 5 s.
    private func waitForRelaySession(_ model: AppModel) async {
        guard let state = try? await client()?.fetchSession(timeout: 5), let id = state.sessionID else { return }
        if model.attributes?.id == id { return }
        LockScreenRecord.add("Player Display: waiting for the Mac’s current player before showing Now Playing")
        await model.reconnect()
        for _ in 0..<25 where model.attributes?.id != id {
            try? await Task.sleep(for: .milliseconds(200))
        }
        if model.attributes?.id != id {
            LockScreenRecord.add("Player Display: the Mac’s current player didn’t arrive in 5 s; showing Now Playing anyway")
        }
    }

    /// Player Display set to Live Activity, showing on, and no card. When the
    /// app opens, after Show Live Activity, and on switching to Live Activity
    /// (`fresh`: also has the relay start a hidden Now Playing session, whose
    /// pushes wake the extension that caches the card's artwork).
    ///
    /// The app is open each time, so it starts the card itself: an app-started
    /// card costs none of iOS's hourly push budget, which pushed starts ran out
    /// of on 24 November 2026. The relay records it and keeps it updated.
    @discardableResult
    func showCard(fresh: Bool = false) async -> Bool {
        // The relay knows whether the Mac has played lately; it refuses if not.
        guard Self.display == .liveActivity, wanted else { return false }
        guard fresh || Card.activities.allSatisfy({ $0.attributes.activityID == "demo" || $0.activityState != .active }) else { return true }
        // For the relay's own starts later (after a break); sending it again does no harm.
        if let token = Card.pushToStartToken {
            relayHasToken = true
            await sendStartToken(token)
        }
        let data: Data
        do {
            guard let answer = try await client()?.requestActivity(fresh: fresh, local: true) else { return false }
            data = answer
        } catch {
            LockScreenRecord.add("Live Activity: the relay didn’t start the card (\(error.localizedDescription))")
            return false
        }
        // Empty: an older relay pushed the card itself.
        guard !data.isEmpty else {
            LockScreenRecord.add("Live Activity: asked the relay for the card\(fresh ? ", with Now Playing hidden" : "")")
            return true
        }
        guard let grant = try? JSONDecoder().decode(LocalCard.self, from: data) else {
            LockScreenRecord.add("Live Activity: couldn’t read the relay’s card")
            return false
        }
        for old in Card.activities where old.attributes.activityID != "demo" {
            await old.end(nil, dismissalPolicy: .immediate)
        }
        do {
            let card = try Card.request(attributes: grant.attributes,
                                        content: ActivityContent(state: grant.content, staleDate: Date().addingTimeInterval(30 * 60)),
                                        pushType: .token)
            LockScreenRecord.add("Live Activity: started the card here\(fresh ? ", with Now Playing hidden" : "")")
            follow(card)
            return true
        } catch {
            LockScreenRecord.add("Live Activity: iOS didn’t start the card (\(error.localizedDescription))")
            try? await client()?.removeActivityToken(activityID: grant.attributes.activityID)
            return false
        }
    }

    /// The relay's answer to a `local` request: what the app starts the card with.
    private struct LocalCard: Decodable {
        var attributes: MacPlaybackActivityAttributes
        var content: MacPlaybackActivityAttributes.ContentState
    }

    private func observeStartTokens() async {
        for await token in Card.pushToStartTokenUpdates where wanted {
            relayHasToken = true
            await sendStartToken(token)
        }
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
        // Started while Second Chair is on screen: the player is already up
        // (the app asked for it when it opened), so the card would be a second
        // one. Not with Player Display set to Live Activity: there the card is the player.
        if Self.display.usesNowPlaying, UIApplication.shared.applicationState == .active, isShowing, card.activityState == .active, id != "demo" {
            following.remove(card.id)
            Task {
                await card.end(nil, dismissalPolicy: .immediate)
                try? await client()?.removeActivityToken(activityID: id)
                LockScreenRecord.add("Live Activity: ended the card at once, since Second Chair is open and showing the player")
            }
            return
        }
        Task {
            for await token in card.pushTokenUpdates {
                let relay = client(), hex = token.hexString
                switch await CardTokenDelivery.deliver({ try await relay?.registerActivityToken(hex, activityID: id) }) {
                case .sent:
                    LockScreenRecord.add("Live Activity: sent the card’s update token")
                case .notTheRelays where id != "demo":
                    // The relay never started this card, or has started another
                    // since, and won't update it: on 26 November 2026 a second
                    // card for one song stayed up, frozen and without artwork.
                    following.remove(card.id)
                    await card.end(nil, dismissalPolicy: .immediate)
                    LockScreenRecord.add("Live Activity: ended a second card for “\(card.content.state.title)”, which the relay doesn’t update")
                    return
                case .notTheRelays:
                    LockScreenRecord.add("Live Activity: the relay doesn’t know the demo card")
                case .failed(let reason):
                    LockScreenRecord.add("Live Activity: couldn’t send the card’s update token (\(reason))")
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
