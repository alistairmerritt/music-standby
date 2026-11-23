import AppIntents
import StandByKit
import SwiftUI
import UIKit

// The Live Activity card's views (experiment; redesigned 24 November 2026 to
// Alistair's brief). The card is a fallback for the Mac's Now Playing player,
// not a second player: artwork-led, content floating on a clear background
// (the Lock Screen does the visual work), controls on the trailing edge, and
// a light progress line. In the shared folder, so development builds can draw
// them in the app too (`-liveActivityPreview`).
//
// The 23 November backdrop (the cover blurred under a black wash) made the
// card read as a dark slab. It's gone: nothing is drawn behind the content.
// 24 November, after seeing it beside Apple's player: the Mac's name moved
// above the title with no symbol, greys matched to Apple's, bigger buttons,
// no cover when there's no artwork, and the remaining time right-aligned.

/// The card's artwork: from the cache the Now Playing extension fills, or the
/// demo's bundled covers. A Live Activity can't use the network, and its
/// images may be no bigger than they're drawn, so it's read small.
enum MacPlaybackCardArtwork {
    static func image(for id: String, pixels: CGFloat = 216) -> UIImage? {
        guard !id.isEmpty else { return nil }
        let data = MockArtwork.cover(id: id) ?? ArtworkStore(container: SharedContainer.appGroup()).load(id: id)
        return data.flatMap(UIImage.init(data:))?.preparingThumbnail(of: CGSize(width: pixels, height: pixels))
    }
}

/// The type the card uses everywhere, matched by eye to Apple's own Lock
/// Screen player (24 Nov 2026): a white title, a grey artist, and a dimmer
/// grey for where it's playing and the times. iOS draws its own glass plate
/// behind a clear tint, so there's no shadow.
enum MacPlaybackCardInk {
    static let primary = Color.white
    static let secondary = Color.white.opacity(0.6)
    static let tertiary = Color.white.opacity(0.45)
    static let bar = Color.white.opacity(0.6)
}

/// The Lock Screen and StandBy card. With no artwork (not cached yet), there's
/// no cover at all rather than an empty box.
struct MacPlaybackCardView: View {
    let attributes: MacPlaybackActivityAttributes
    let state: MacPlaybackActivityAttributes.ContentState
    let artwork: UIImage?

    init(attributes: MacPlaybackActivityAttributes, state: MacPlaybackActivityAttributes.ContentState) {
        self.attributes = attributes
        self.state = state
        artwork = MacPlaybackCardArtwork.image(for: state.artworkID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                if let artwork { MacPlaybackCardCover(image: artwork, size: 60) }
                MacPlaybackCardTitles(attributes: attributes, state: state, titleSize: 17)
                Spacer(minLength: 4)
                MacPlaybackCardButtons(state: state, glyph: 30)
            }
            MacPlaybackCardProgress(state: state)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }
}

/// Where it's playing (the Mac's name), then the song and artist: Apple's
/// order, with the source small and dim on top.
struct MacPlaybackCardTitles: View {
    let attributes: MacPlaybackActivityAttributes
    let state: MacPlaybackActivityAttributes.ContentState
    let titleSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(attributes.macName)
                .font(.system(size: titleSize - 4, weight: .medium))
                .foregroundStyle(MacPlaybackCardInk.tertiary)
                .padding(.bottom, 1)
            Text(state.hasSong ? state.title : "Nothing playing")
                .font(.system(size: titleSize, weight: .semibold))
                .foregroundStyle(MacPlaybackCardInk.primary)
            if state.hasSong {
                Text(state.artist)
                    .font(.system(size: titleSize))
                    .foregroundStyle(MacPlaybackCardInk.secondary)
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}

struct MacPlaybackCardCover: View {
    let image: UIImage
    let size: CGFloat

    var body: some View {
        Image(uiImage: image).resizable().scaledToFill()
            .frame(width: size, height: size)
            .clipShape(.rect(cornerRadius: size * 0.17, style: .continuous))
    }
}

/// Play/pause and next on the trailing edge, at about the size of Apple's
/// own transport glyphs. On a locked phone iOS asks for Face ID before
/// running them (Apple's rule for widget and Live Activity buttons; seen
/// 23 Nov 2026).
struct MacPlaybackCardButtons: View {
    let state: MacPlaybackActivityAttributes.ContentState
    /// The play/pause glyph's point size; next is drawn a little smaller, as Apple does.
    let glyph: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Button(intent: ActivityPlayPauseOnMacIntent()) {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: glyph))
                    .frame(width: glyph * 1.6, height: glyph * 1.8)
                    .contentShape(.rect)
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(state.isPlaying ? "Pause on Mac" : "Play on Mac")
            Button(intent: ActivityNextOnMacIntent()) {
                Image(systemName: "forward.fill")
                    .font(.system(size: glyph * 0.82))
                    .frame(width: glyph * 1.6, height: glyph * 1.8)
                    .contentShape(.rect)
            }
            .disabled(!state.canGoNext)
            .opacity(state.canGoNext ? 1 : 0.35)
            .accessibilityLabel("Next Song on Mac")
        }
        .buttonStyle(.plain)
        .foregroundStyle(MacPlaybackCardInk.primary)
    }
}

/// A thin line with the elapsed and remaining times beneath it. While
/// playing, the system runs both from the start and end times, so the card
/// moves without pushes; paused, it holds still.
struct MacPlaybackCardProgress: View {
    let state: MacPlaybackActivityAttributes.ContentState
    var showsTimes = true

    var body: some View {
        VStack(spacing: 5) {
            bar
            if showsTimes, state.duration > 0 { times }
        }
    }

    private var range: ClosedRange<Date> { state.startedAt...state.startedAt.addingTimeInterval(max(state.duration, 1)) }

    @ViewBuilder private var bar: some View {
        Group {
            if state.isPlaying, state.duration > 0 {
                ProgressView(timerInterval: range, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
            } else {
                ProgressView(value: state.progress)
            }
        }
        .progressViewStyle(.linear)
        .tint(MacPlaybackCardInk.bar)
        .labelsHidden()
    }

    private var times: some View {
        // A timer text takes all the width it's offered and draws at its
        // leading edge, so each side gets half and the remaining time is
        // aligned to the trailing edge explicitly (it sat mid-card before).
        HStack(spacing: 0) {
            Group {
                if state.isPlaying { Text(timerInterval: range, countsDown: false) } else { Text(Self.clock(state.elapsed)) }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                if state.isPlaying {
                    Text("−") + Text(timerInterval: range, countsDown: true)
                } else {
                    Text("−" + Self.clock(max(state.duration - state.elapsed, 0)))
                }
            }
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .medium).monospacedDigit())
        .foregroundStyle(MacPlaybackCardInk.tertiary)
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
