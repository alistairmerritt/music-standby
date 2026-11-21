import StandByKit
import SwiftUI

/// The paired Mac and whether it's reachable, as a card with a coloured
/// pill (21 November 2026, after a widget app Alistair liked). On Home and
/// at the top of Settings. It says only what the connection says: never
/// that the Lock Screen player is showing.
struct ConnectionCard: View {
    let macName: String
    let connection: ConnectionState
    var isDemo = false
    /// Offered when the Mac can't be reached. Nil hides the button.
    var reconnect: (() -> Void)?

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(tone.color)
                    .frame(width: 40, height: 40)
                    .background(tone.color.opacity(0.15), in: .circle)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(macName)
                        .font(.headline)
                        .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                    // At the largest sizes the pill goes under the name, which
                    // was squeezed to "Mac…" beside it (22 November 2026).
                    if typeSize.isAccessibilitySize {
                        StatusPill(text: label, color: tone.color, isWorking: tone == .working).padding(.top, 4)
                    }
                    if let detail {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !typeSize.isAccessibilitySize {
                    StatusPill(text: label, color: tone.color, isWorking: tone == .working)
                }
            }
            if needsAttention, let reconnect {
                Button("Reconnect", action: reconnect)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.leading, 52)
            }
        }
        .padding(14)
        .background(.fill.quaternary, in: .rect(cornerRadius: 18))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(macName), \(label)")
    }

    private enum Tone: Equatable {
        case good, working, problem, neutral

        var color: Color {
            switch self {
            case .good: .green
            case .working: .orange
            case .problem: .red
            case .neutral: .secondary
            }
        }
    }

    private var tone: Tone {
        if isDemo { return .neutral }
        return switch connection {
        case .connected: .good
        case .connecting, .reconnecting: .working
        case .macOffline, .disconnected, .failed: .problem
        }
    }

    private var label: String {
        isDemo ? "Demo" : connection.summary
    }

    private var needsAttention: Bool { tone == .problem }

    /// A line under the name, only when there's something to do.
    private var detail: String? {
        if isDemo { return "A simulated Mac" }
        return switch connection {
        case .macOffline: "Wake your Mac and check Second Chair is open on it."
        case .disconnected: "Check this iPhone is online."
        case .failed(let reason): reason
        case .connected, .connecting, .reconnecting: nil
        }
    }
}

/// "● Connected": a dot and a word on a tinted capsule.
struct StatusPill: View {
    let text: String
    let color: Color
    var isWorking = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                // A slow pulse while connecting; still with Reduce Motion.
                .phaseAnimator(isWorking && !reduceMotion ? [1.0, 0.35] : [1.0]) { dot, opacity in dot.opacity(opacity) }
                    animation: { _ in .easeInOut(duration: 0.8) }
            Text(text)
                .font(.footnote.weight(.medium))
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.15), in: .capsule)
        .fixedSize()
    }
}
