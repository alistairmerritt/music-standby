import CoreHaptics
import Observation
import SwiftUI

/// Which way the music moves in a hand-over started on Home.
enum HandoffDirection: Hashable {
    case toPhone, toMac
}

/// Home's hand-over moment: the Continue buttons start it and the artwork shows it.
/// Only for hand-overs started in the app; the widget, Shortcuts and CarPlay
/// ones happen with nothing on screen (23 November 2026).
enum HandoffPhase: Equatable {
    case moving(HandoffDirection)
    case landed(HandoffDirection)

    var direction: HandoffDirection {
        switch self {
        case .moving(let d), .landed(let d): d
        }
    }

    var isMoving: Bool {
        if case .moving = self { true } else { false }
    }
}

/// A hand-over in the spirit of Apple's HomePod and AirDrop ones (as filmed in
/// 2020–21, researched 23 November 2026). It all comes from the top of the
/// screen, where the Mac's card and the Dynamic Island are, the way Apple's
/// start where the other device is:
/// - while the music moves, light gathers at the top edge and taps build up,
///   as they do bringing an iPhone to a HomePod;
/// - when it lands, a ripple of light runs down through the whole screen from
///   the top, the same for Continue on iPhone and Continue on Mac (Alistair,
///   23 November 2026: they shouldn't be opposites), with one firm tap, as AirDrop's does when two iPhones meet.
@MainActor
@Observable
final class HandoffMoment {
    static let shared = HandoffMoment()

    private(set) var phase: HandoffPhase?
    /// Goes up by one each time a hand-over lands; plays the ripple.
    private(set) var landings = 0

    /// Where the music went, assumed from the moment it lands until Home has
    /// seen it for itself: Apple Music here reports in a moment and the Mac's
    /// pause comes through the relay, so Home went through three sets of
    /// buttons in 1¼ s after the ripple (Alistair's recording, 23 November
    /// 2026). Now it shows where the music went with the ripple, once.
    private(set) var assumed: HandoffDirection?

    /// While a hand-over has just landed: true if the iPhone plays the Mac's
    /// song now, false if the Mac does; nil otherwise.
    var assumesPhonePlays: Bool? { assumed.map { $0 == .toPhone } }

    @ObservationIgnored private let haptics = HandoffHaptics()

    func begin(_ direction: HandoffDirection) {
        assumed = nil
        phase = .moving(direction)
        haptics.build()
    }

    func land(_ direction: HandoffDirection) {
        phase = .landed(direction)
        assumed = direction
        landings += 1
        let landing = landings
        haptics.land()
        Task {
            // Long enough for the Mac's state to come through the relay.
            try? await Task.sleep(for: .seconds(5))
            if landings == landing { assumed = nil }
        }
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            if phase == .landed(direction) { phase = nil }
        }
    }

    func fail() {
        phase = nil
        assumed = nil
        haptics.stop()
    }

    /// The hand-over said it didn't work after all: show what's real.
    func forgetAssumption() {
        assumed = nil
    }
}

// MARK: The whole screen

/// Goes around Home's navigation, so the light covers the title too. The
/// ripple itself bends only Home's background (`HandoffBackgroundRipple`):
/// SwiftUI's shaders can't redraw the parts of Home that UIKit draws (the
/// navigation and the scroll view), and show a placeholder instead.
struct HandoffEffect: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let moment = HandoffMoment.shared

    func body(content: Content) -> some View {
        content
            .overlay {
                if !reduceMotion {
                    Color.clear
                        .keyframeAnimator(initialValue: 0.0, trigger: moment.landings) { view, progress in
                            view.overlay { LightBand(progress: progress) }
                        } keyframes: { _ in
                            LinearKeyframe(0.0, duration: 0.01)
                            CubicKeyframe(1.0, duration: 1.1)
                        }
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .top) {
                if moment.phase?.isMoving == true, !reduceMotion {
                    TopEdgeLight()
                        .transition(.opacity.animation(.easeOut(duration: 0.4)))
                }
            }
            .animation(.easeInOut(duration: 0.35), value: moment.phase?.isMoving)
    }
}

/// Home's background, bent by the ripple as the music lands.
struct HandoffBackgroundRipple: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let moment = HandoffMoment.shared

    func body(content: Content) -> some View {
        content
            .keyframeAnimator(initialValue: 0.0, trigger: moment.landings) { view, progress in
                view.visualEffect { view, proxy in
                    view.layerEffect(
                        ShaderLibrary.handoffRipple(
                            .float2(proxy.size),
                            // The Dynamic Island, at the top of the screen.
                            .float2(proxy.size.width / 2, -24),
                            .float(progress),
                            .float(1)),
                        maxSampleOffset: CGSize(width: 24, height: 24),
                        isEnabled: !reduceMotion && progress > 0 && progress < 1)
                }
            } keyframes: { _ in
                LinearKeyframe(0.0, duration: 0.01)
                CubicKeyframe(1.0, duration: 1.1)
            }
    }
}

/// A band of light that runs through the whole screen from the top edge: down
/// and out as the music arrives, back up into the top as it leaves.
private struct LightBand: View {
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            let reach = hypot(proxy.size.width / 2, proxy.size.height) + 140
            let travelled = progress
            let front = max(0.001, travelled)
            let width = 0.09
            let strength = sin(progress * .pi)
            Rectangle()
                .fill(RadialGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .clear, location: max(0, front - width)),
                    .init(color: .white.opacity(0.55), location: front),
                    .init(color: .clear, location: min(1, front + width * 0.6)),
                    .init(color: .clear, location: 1),
                ], center: UnitPoint(x: 0.5, y: -24 / max(proxy.size.height, 1)), startRadius: 0, endRadius: reach))
                .opacity(strength)
                .blendMode(.plusLighter)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Light gathering at the top edge, around the Dynamic Island, breathing
/// while the music moves.
private struct TopEdgeLight: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let breath = 0.65 + 0.35 * sin(t * 2 * .pi / 1.4)
            ZStack {
                Ellipse()
                    .fill(RadialGradient(colors: [.white.opacity(0.9), .white.opacity(0.25), .clear],
                                         center: .center, startRadius: 0, endRadius: 170))
                    .frame(width: 360, height: 220)
                    .blur(radius: 26)
                    .opacity(0.55 * breath)
                Capsule()
                    .fill(.white)
                    .frame(width: 150, height: 40)
                    .blur(radius: 18)
                    .opacity(0.8 * breath)
            }
            .offset(y: -120)
        }
        .blendMode(.plusLighter)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: The artwork

/// The artwork's part: it settles with a small dip and bounce when the music lands.
struct HandoffArtwork<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let moment = HandoffMoment.shared

    var body: some View {
        content()
            .keyframeAnimator(initialValue: 1.0, trigger: moment.landings) { view, scale in
                view.scaleEffect(reduceMotion ? 1 : scale)
            } keyframes: { _ in
                LinearKeyframe(1.0, duration: 0.15)
                CubicKeyframe(0.93, duration: 0.12)
                SpringKeyframe(1.0, duration: 0.55, spring: .bouncy)
            }
    }
}

// MARK: Haptics

/// Taps that build while the music moves, as bringing an iPhone to a HomePod
/// does, then one firm tap when it lands.
@MainActor
private final class HandoffHaptics {
    private var engine: CHHapticEngine?
    private var building: CHHapticAdvancedPatternPlayer?

    private func ready() -> CHHapticEngine? {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return nil }
        if engine == nil {
            engine = try? CHHapticEngine()
            // Taps only, never sound, so the engine has no reason to touch
            // audio while Apple Music plays (23 November 2026, investigating
            // pauses; Apple's documentation doesn't say whether it would).
            engine?.playsHapticsOnly = true
            engine?.isAutoShutdownEnabled = true
        }
        try? engine?.start()
        return engine
    }

    func build() {
        stop()
        guard let engine = ready() else { return }
        // Taps closer together and stronger over 2.4 s; a hand-over takes 1–3 s.
        var events: [CHHapticEvent] = []
        var time = 0.0, gap = 0.34
        while time < 2.4 {
            let progress = Float(time / 2.4)
            events.append(CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.25 + 0.5 * progress),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.3 + 0.3 * progress),
            ], relativeTime: time))
            time += gap
            gap = max(0.12, gap * 0.85)
        }
        guard let pattern = try? CHHapticPattern(events: events, parameters: []),
              let player = try? engine.makeAdvancedPlayer(with: pattern) else { return }
        building = player
        try? player.start(atTime: CHHapticTimeImmediate)
    }

    func land() {
        stop()
        guard let engine = ready() else { return }
        let events = [
            CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.55),
            ], relativeTime: 0),
            CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.45),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.2),
            ], relativeTime: 0.02, duration: 0.18),
        ]
        guard let pattern = try? CHHapticPattern(events: events, parameters: []),
              let player = try? engine.makePlayer(with: pattern) else { return }
        try? player.start(atTime: CHHapticTimeImmediate)
    }

    func stop() {
        try? building?.stop(atTime: CHHapticTimeImmediate)
        building = nil
    }
}
