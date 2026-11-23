import StandByKit
import SwiftUI

/// Continue on iPhone and Continue on Mac on Home: the one prominent
/// button, and a second when both directions are open (21 November 2026
/// redesign). Which directions are offered is decided exactly as before
/// (`HandoffSection` until then); only the presentation changed:
/// - a direction that can't be used now is left out rather than greyed;
/// - with nothing wrong there's no status row; a problem shows as a note
///   with its fix, in place of the buttons it stops.
struct ContinueListeningArea: View {
    @Environment(AppModel.self) private var model
    let player: SystemMusicPhonePlayer
    @Binding var here: PhoneNowPlaying?
    /// Whether Continue Listening can work, and what to do if not. Nil when
    /// there's nothing to say yet.
    let status: ContinueListeningStatus?
    let allowAppleMusic: (_ canAsk: Bool) async -> Void
    /// Continue Listening's setup, from the first run.
    let setUp: () -> Void
    /// Both directions quiet, when Home's accent is elsewhere (Open Apple Music).
    var quiet = false

    private typealias Direction = HandoffDirection
    @State private var working: Direction?
    @State private var result: (text: String, isFailure: Bool)?

    // Just after a hand-over lands, where the music went (HandoffMoment).
    private var assumed: Bool? { HandoffMoment.shared.assumesPhonePlays }
    private var macPlaying: Bool {
        if let assumed { return !assumed }
        return model.attributes?.isPlaying == true
    }
    private var phonePlaying: Bool {
        if let assumed { return assumed }
        #if DEBUG
        if ScreenshotMode.iPhonePlaying { return true }
        #endif
        return here?.isPlaying == true
    }
    private var phoneSongInMacQueue: Bool {
        if assumed == true { return true }
        #if DEBUG
        if ScreenshotMode.iPhonePlaying { return true }
        #endif
        return model.macQueuePosition(of: here?.catalogID) != nil
    }
    /// Any Apple Music song can go to the Mac: one its queue doesn't have goes as its station.
    private var phoneHasAppleMusicSong: Bool {
        if assumed == true { return true }
        #if DEBUG
        if ScreenshotMode.iPhonePlaying { return true }
        #endif
        return here?.catalogID != nil
    }

    // The rules as they were: offered, then open.
    /// Whenever the Mac's song can move.
    private var showsContinueOnPhone: Bool {
        #if DEBUG
        // Screenshots of nothing playing hide the demo Mac's song, as a real Mac would have none.
        if HomeScreenshot.nothingPlaying { return false }
        #endif
        return model.canContinueOnPhone
    }
    /// While the phone plays, or when its paused song is one the Mac has; not
    /// for whatever Apple Music here last played long ago.
    private var showsContinueOnMac: Bool { phonePlaying || phoneSongInMacQueue }
    private var continueOnPhoneOpen: Bool { !(phonePlaying && !macPlaying) }
    private var continueOnMacOpen: Bool { phoneHasAppleMusicSong && !(macPlaying && !phonePlaying) }

    /// A status that stops both directions: the Mac's Music isn't connected,
    /// or Apple Music here isn't allowed.
    private var blocked: Bool {
        switch status {
        case .setUpOnMac?, .reconnectOnMac?, .allowAppleMusic?: true
        default: false
        }
    }

    private var toPhone: Bool { !blocked && status != .needsAppleMusic && showsContinueOnPhone && continueOnPhoneOpen }
    /// Continue on Mac stays in place while it's on offer and only greys out
    /// while the Mac plays, so pausing and playing the Mac doesn't make it come
    /// and go and move everything below it (Alistair, 23 November 2026).
    private var toMac: Bool { !blocked && showsContinueOnMac && phoneHasAppleMusicSong }
    private var toMacEnabled: Bool { continueOnMacOpen }

    var body: some View {
        VStack(spacing: 14) {
            // A problem shows only when there is something to continue.
            if showsContinueOnPhone || showsContinueOnMac, let note { note }
            // Moving back comes first while the iPhone has the music. The
            // buttons are slots, not directions: through a hand-over the first
            // button stays the same button and morphs, its words, symbol and
            // colour changing in place, rather than one button fading out for
            // another to fade in (Alistair, 23 November 2026: "much more fluid").
            ForEach(Array(order.enumerated()), id: \.offset) { slot, direction in
                action(direction, prominent: slot == 0)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
            if let result {
                Text(result.text)
                    .font(.footnote)
                    .foregroundStyle(result.isFailure ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .transition(.opacity)
            }
        }
        // One spring for all of it, the same as the panel's, with no delays.
        .animation(.smooth(duration: 0.45), value: order)
        .animation(.smooth(duration: 0.45), value: quiet)
        .animation(.smooth(duration: 0.45), value: toMacEnabled)
        .animation(.smooth(duration: 0.45), value: working)
        .animation(.smooth(duration: 0.45), value: result?.text)
        .onChange(of: [macPlaying, phonePlaying]) { result = nil }
        #if DEBUG
        .onChange(of: DemoHandover.shared.autoRuns) {
            Task { await run(DemoHandover.shared.autoDirection) }
        }
        #endif
    }

    /// The buttons shown, the one to use most likely first.
    private var order: [Direction] {
        var shown: [Direction] = []
        if phonePlaying {
            if toMac { shown.append(.toMac) }
            if toPhone { shown.append(.toPhone) }
        } else {
            if toPhone { shown.append(.toPhone) }
            if toMac { shown.append(.toMac) }
        }
        return shown
    }

    private func action(_ direction: Direction, prominent: Bool) -> some View {
        let toPhone = direction == .toPhone
        let title = toPhone ? "Continue on iPhone" : "Continue on Mac"
        let symbol = toPhone ? "iphone" : "laptopcomputer"
        // "will pause" only when the other side is playing (Alistair, 23 November 2026).
        let detail: String = if toPhone {
            (model.macSongHasNoCatalogID
                ? "Finds this song in Apple Music and picks up from the same point."
                : "Picks up here from the same point.")
                + (macPlaying ? " Your Mac will pause." : "")
        } else {
            phoneSongInMacQueue
                ? "Picks up on your Mac from the same point." + (phonePlaying ? " Your iPhone will pause." : "")
                : "Picks up on your Mac. If your Mac can’t play this playlist or album, it plays the song’s station."
        }
        return VStack(spacing: 8) {
            Button {
                Task { await run(direction) }
            } label: {
                HStack(spacing: 8) {
                    if working == direction {
                        ProgressView()
                            .transition(.opacity.combined(with: .scale(scale: 0.6)))
                    } else {
                        Image(systemName: symbol)
                            .contentTransition(.symbolEffect(.replace))
                            .transition(.opacity.combined(with: .scale(scale: 0.6)))
                    }
                    Text(working == direction ? (toPhone ? "Continuing on iPhone…" : "Continuing on Mac…") : title)
                        .contentTransition(.interpolate)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(ContinueButtonStyle(prominent: prominent && !quiet))
            .disabled(working != nil || (direction == .toMac && !toMacEnabled))
            .accessibilityHint(detail)
            if result == nil {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .contentTransition(.interpolate)
                    .accessibilityHidden(true)
                    .opacity(direction == .toMac && !toMacEnabled ? 0.5 : 1)
            }
        }
    }

    private func run(_ direction: Direction) async {
        working = direction
        result = nil
        HandoffMoment.shared.begin(direction)
        // The ripple and the firm tap land the moment the music moves, while
        // the hand-over finishes off (HandoffMoment, 23 November 2026).
        var landed = false
        let arrived: @MainActor () -> Void = {
            guard !landed else { return }
            landed = true
            HandoffMoment.shared.land(direction)
        }
        let outcome: (text: String, isFailure: Bool)?
        #if DEBUG
        if ScreenshotMode.isOn {
            outcome = await DemoHandover.shared.run(direction, model: model, arrived: arrived)
        } else {
            outcome = direction == .toPhone ? await continueHere(arrived) : await sendBack(arrived)
        }
        #else
        outcome = direction == .toPhone ? await continueHere(arrived) : await sendBack(arrived)
        #endif
        result = outcome
        if outcome == nil || outcome?.isFailure == false {
            arrived()
        } else if !landed {
            HandoffMoment.shared.fail()
        } else {
            // It moved, then something failed (the Mac wouldn't pause): show what's real.
            HandoffMoment.shared.forgetAssumption()
        }
        here = player.nowPlaying()
        working = nil
    }

    private func continueHere(_ arrived: @escaping @MainActor () -> Void) async -> (text: String, isFailure: Bool)? {
        switch await model.continueOnPhone(with: player, arrived: arrived) {
        case .unavailable: ("This song couldn’t be found in Apple Music.", true)
        case .notAllowed: ("Allow access to Apple Music in Settings to continue listening on your iPhone.", true)
        case .didNotStart: ("Couldn’t start playback on your iPhone. Music is still playing on your Mac.", true)
        // Stays here (17 November 2026): Home says the song is on the
        // iPhone, and Continue on Mac is at hand. The Shortcuts action
        // still opens Music unless told not to.
        case .continued, .macStillPlaying, .resumedHere, .alreadyPlayingHere: nil
        }
    }

    private func sendBack(_ arrived: @escaping @MainActor () -> Void) async -> (text: String, isFailure: Bool)? {
        let outcome = await model.sendBackToMac(with: player, arrived: arrived)
        // Say only what's true now: headphones moving over can pause Apple Music here by themselves.
        let stillHere = player.nowPlaying()?.isPlaying == true ? " Music is still playing on your iPhone." : ""
        return switch outcome {
        case .sentAsStation: ("Your Mac is playing the station, which started with another song.", false)
        case .macRefused: ("Couldn’t start playback on your Mac." + stillHere, true)
        case .macDidNotStart: ("Your Mac didn’t respond. Try again." + stillHere, true)
        case .sentBack, .nothingPlayingHere: nil
        }
    }

    /// A problem that stops Continue Listening, with its fix. Nothing when it's ready.
    private var note: Notice? {
        switch status {
        case .setUpOnMac?:
            Notice(symbol: "laptopcomputer", title: "Continue Listening isn’t set up.",
                   text: "Connect Music on your Mac to move your music between your Mac and iPhone.",
                   button: "Set Up", action: setUp)
        case .reconnectOnMac?:
            Notice(symbol: "laptopcomputer", title: "Reconnect Music on your Mac",
                   text: "Music on your Mac no longer recognises Second Chair.",
                   button: "Set Up", action: setUp)
        case .allowAppleMusic(let canAsk)?:
            Notice(symbol: "music.note", title: "Allow Apple Music",
                   text: "Continue Listening plays your music in Apple Music on this iPhone.",
                   button: canAsk ? "Allow" : "Open Settings") { Task { await allowAppleMusic(canAsk) } }
        case .needsAppleMusic?:
            // Continue on Mac may still be open, so a quiet line, not a box.
            Notice(symbol: nil, title: nil,
                   text: "Continue on iPhone needs an Apple Music subscription.", button: nil, action: nil)
        case .ready?, nil:
            nil
        }
    }
}

/// The one accent on Home, or its quieter second.
/// Drawn rather than the system's bordered styles, so that a button going
/// from the accent to the quiet style blends its colour instead of switching
/// (23 November 2026).
private struct ContinueButtonStyle: ButtonStyle {
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(prominent ? Color.white : Color.accentColor)
            .padding(.horizontal, 20)
            .frame(minHeight: 50)
            .background(Capsule().fill(prominent ? Color.accentColor : Color.primary.opacity(0.12)))
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.smooth(duration: 0.2), value: configuration.isPressed)
    }
}

/// A short note on Home with, usually, one button to fix it.
struct Notice: View {
    let symbol: String?
    let title: String?
    let text: String
    let button: String?
    let action: (() -> Void)?

    var body: some View {
        if title == nil, button == nil {
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                if let symbol {
                    Image(systemName: symbol).foregroundStyle(.secondary)
                }
                // The button goes under the words, so they have the full
                // width (the demo's banner wrapped to seven lines beside it,
                // 21 November 2026).
                VStack(alignment: .leading, spacing: 2) {
                    if let title { Text(title).font(.subheadline.weight(.semibold)) }
                    Text(text).font(.subheadline).foregroundStyle(.secondary)
                    if let button, let action {
                        Button(button, action: action)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .padding(.top, 8)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .background(.fill.quaternary, in: .rect(cornerRadius: 14))
            .accessibilityElement(children: .contain)
        }
    }
}
