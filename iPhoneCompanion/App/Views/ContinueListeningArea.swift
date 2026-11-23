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

    private var macPlaying: Bool { model.attributes?.isPlaying == true }
    private var phonePlaying: Bool {
        #if DEBUG
        if ScreenshotMode.iPhonePlaying { return true }
        #endif
        return here?.isPlaying == true
    }
    private var phoneSongInMacQueue: Bool {
        #if DEBUG
        if ScreenshotMode.iPhonePlaying { return true }
        #endif
        return model.macQueuePosition(of: here?.catalogID) != nil
    }
    /// Any Apple Music song can go to the Mac: one its queue doesn't have goes as its station.
    private var phoneHasAppleMusicSong: Bool {
        #if DEBUG
        if ScreenshotMode.iPhonePlaying { return true }
        #endif
        return here?.catalogID != nil
    }

    // The rules as they were: offered, then open.
    /// Whenever the Mac's song can move.
    private var showsContinueOnPhone: Bool { model.canContinueOnPhone }
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
    private var toMac: Bool { !blocked && showsContinueOnMac && continueOnMacOpen }

    var body: some View {
        VStack(spacing: 14) {
            // A problem shows only when there is something to continue.
            if showsContinueOnPhone || showsContinueOnMac, let note { note }
            // Moving back comes first while the iPhone has the music. A new
            // set of buttons is a new block: the old one fades out quickly and
            // the new one fades in a beat later, once the panel above has
            // changed, so they never cross (23 November 2026).
            VStack(spacing: 14) {
                ForEach(order, id: \.self) { direction in
                    action(direction, prominent: direction == order.first)
                }
            }
            .id(ButtonSet(order: order, quiet: quiet))
            .transition(.asymmetric(insertion: .opacity.animation(.smooth(duration: 0.4).delay(0.3)),
                                    removal: .opacity.animation(.easeOut(duration: 0.15))))
            if let result {
                Text(result.text)
                    .font(.footnote)
                    .foregroundStyle(result.isFailure ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.4), value: ButtonSet(order: order, quiet: quiet))
        .animation(.smooth(duration: 0.3), value: result?.text)
        .onChange(of: [macPlaying, phonePlaying]) { result = nil }
        #if DEBUG
        .onChange(of: DemoHandover.shared.autoRuns) {
            Task { await run(DemoHandover.shared.autoDirection) }
        }
        #endif
    }

    /// What makes a set of buttons different enough to fade between.
    private struct ButtonSet: Hashable {
        let order: [Direction]
        let quiet: Bool
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
        let detail: String = if toPhone {
            model.macSongHasNoCatalogID
                ? "Finds this song in Apple Music and picks up from the same point. Your Mac will pause."
                : "Picks up here from the same point. Your Mac will pause."
        } else {
            phoneSongInMacQueue
                ? "Picks up on your Mac from the same point. Your iPhone will pause."
                : "Picks up on your Mac. If your Mac can’t play this playlist or album, it plays the song’s station."
        }
        return VStack(spacing: 8) {
            Button {
                Task { await run(direction) }
            } label: {
                HStack(spacing: 8) {
                    if working == direction {
                        ProgressView()
                        Text(toPhone ? "Continuing on iPhone…" : "Continuing on Mac…")
                    } else {
                        Label(title, systemImage: symbol)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .modifier(ContinueButtonStyle(prominent: prominent && !quiet))
            .disabled(working != nil)
            .accessibilityHint(detail)
            if result == nil {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
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
private struct ContinueButtonStyle: ViewModifier {
    let prominent: Bool

    func body(content: Content) -> some View {
        if prominent {
            content.buttonStyle(.borderedProminent).controlSize(.large)
        } else {
            content.buttonStyle(.bordered).controlSize(.large)
        }
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
