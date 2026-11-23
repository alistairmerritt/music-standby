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

/// The two ideas being compared (23 November 2026). Development builds pick one
/// with `-handoffStyle flight|ripple`.
enum HandoffStyle: String {
    /// The artwork lifts while the music moves, then a copy of it flies between
    /// the Mac's card and the artwork, and the artwork settles with a bounce.
    case flight
    /// Rings pulse from the artwork while the music moves, outwards towards the
    /// Mac or inwards to the iPhone, and the artwork settles with a bounce.
    case ripple

    static var current: HandoffStyle {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let at = arguments.firstIndex(of: "-handoffStyle"), arguments.count > at + 1,
           let style = HandoffStyle(rawValue: arguments[at + 1]) { return style }
        #endif
        return .ripple
    }
}

/// The artwork's part in a hand-over. `landings` goes up by one each time
/// a hand-over lands, which plays the settle.
struct HandoffArtwork<Content: View>: View {
    let phase: HandoffPhase?
    let landings: Int
    let cornerRadius: CGFloat
    @ViewBuilder let content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let style = HandoffStyle.current

    private var lifts: Bool { style == .flight && phase?.isMoving == true && !reduceMotion }

    var body: some View {
        content()
            .scaleEffect(lifts ? 1.05 : 1)
            .offset(y: lifts ? -6 : 0)
            .shadow(color: .white.opacity(lifts ? 0.3 : 0), radius: lifts ? 22 : 0)
            .background {
                if style == .ripple, let phase, phase.isMoving, !reduceMotion {
                    RippleRings(inward: phase.direction == .toPhone, cornerRadius: cornerRadius)
                        .transition(.opacity)
                }
            }
            .overlay {
                if style == .flight, !reduceMotion {
                    FlightCopy(toMac: phase?.direction == .toMac, trigger: landings, content: content)
                }
            }
            .keyframeAnimator(initialValue: 1.0, trigger: landings) { view, scale in
                view.scaleEffect(reduceMotion ? 1 : scale)
            } keyframes: { _ in
                CubicKeyframe(0.94, duration: 0.12)
                SpringKeyframe(1.0, duration: 0.5, spring: .bouncy)
            }
            .animation(.spring(response: 0.45, dampingFraction: 0.75), value: phase)
    }
}

/// Rings that pulse from the artwork while the music moves.
private struct RippleRings: View {
    let inward: Bool
    let cornerRadius: CGFloat

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<3, id: \.self) { ring in
                    let cycle = (t / 1.5 + Double(ring) / 3).truncatingRemainder(dividingBy: 1)
                    let p = inward ? 1 - cycle : cycle
                    RoundedRectangle(cornerRadius: cornerRadius + 24 * p)
                        .strokeBorder(.white.opacity(0.55 * (1 - p)), lineWidth: 2)
                        .scaleEffect(1 + 0.55 * p)
                }
            }
        }
        .blur(radius: 0.6)
        .allowsHitTesting(false)
    }
}

/// A copy of the artwork that flies between the Mac's card, above, and the
/// artwork when a hand-over lands. Invisible otherwise.
private struct FlightCopy<Content: View>: View {
    let toMac: Bool
    let trigger: Int
    @ViewBuilder let content: () -> Content

    private struct Flight {
        var y: CGFloat = 0
        var scale: CGFloat = 1
        var opacity: Double = 0
    }

    /// About the distance up to the Mac's card.
    private let rise: CGFloat = -170

    var body: some View {
        content()
            .keyframeAnimator(initialValue: Flight(), trigger: trigger) { view, f in
                view.scaleEffect(f.scale).offset(y: f.y).opacity(f.opacity)
            } keyframes: { _ in
                KeyframeTrack(\.y) {
                    LinearKeyframe(toMac ? 0 : rise, duration: 0.01)
                    CubicKeyframe(toMac ? rise : 0, duration: 0.6)
                }
                KeyframeTrack(\.scale) {
                    LinearKeyframe(toMac ? 1 : 0.25, duration: 0.01)
                    CubicKeyframe(toMac ? 0.25 : 1, duration: 0.6)
                }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(toMac ? 0.9 : 0, duration: 0.01)
                    LinearKeyframe(toMac ? 0.6 : 0.9, duration: 0.3)
                    LinearKeyframe(0, duration: 0.3)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
