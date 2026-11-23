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

/// The type the card uses everywhere. White, like the Lock Screen's own clock
/// and text, since the card sits on the wallpaper with no fill behind it; a
/// soft shadow keeps it legible on a pale wallpaper without a container.
enum MacPlaybackCardInk {
    static let primary = Color.white
    static let secondary = Color.white.opacity(0.8)
    static let tertiary = Color.white.opacity(0.62)
    static let track = Color.white.opacity(0.24)
}

private struct LegibleOnWallpaper: ViewModifier {
    func body(content: Content) -> some View {
        content.shadow(color: .black.opacity(0.34), radius: 8, y: 1)
    }
}

/// The Lock Screen and StandBy card.
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
            HStack(alignment: .center, spacing: 14) {
                MacPlaybackCardCover(image: artwork, size: 68)
                MacPlaybackCardTitles(attributes: attributes, state: state, titleSize: 17)
                Spacer(minLength: 6)
                MacPlaybackCardButtons(state: state, size: 40)
            }
            MacPlaybackCardProgress(state: state)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .modifier(LegibleOnWallpaper())
    }
}

/// Song, artist, and where it's playing: "MacBook Pro" with a Mac symbol,
/// subtle but always there, since the card stands for the Mac's playback.
struct MacPlaybackCardTitles: View {
    let attributes: MacPlaybackActivityAttributes
    let state: MacPlaybackActivityAttributes.ContentState
    let titleSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(state.hasSong ? state.title : "Nothing playing")
                .font(.system(size: titleSize, weight: .semibold))
                .foregroundStyle(MacPlaybackCardInk.primary)
            if state.hasSong {
                Text(state.artist)
                    .font(.system(size: titleSize - 2))
                    .foregroundStyle(MacPlaybackCardInk.secondary)
            }
            Label {
                Text(attributes.macName)
            } icon: {
                Image(systemName: "laptopcomputer")
            }
            .labelStyle(SourceLabelStyle())
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(MacPlaybackCardInk.tertiary)
            .padding(.top, 3)
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}

private struct SourceLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 11, weight: .medium))
            configuration.title
        }
    }
}

struct MacPlaybackCardCover: View {
    let image: UIImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(.white.opacity(0.14))
                    .overlay(Image(systemName: "music.note").font(.system(size: size * 0.34)).foregroundStyle(MacPlaybackCardInk.secondary))
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: size * 0.17, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.17, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        }
    }
}

/// Play/pause and next, as a tight cluster on the trailing edge. The targets
/// are full size even where the glyphs are small. On a locked phone iOS asks
/// for Face ID before running them (Apple's rule for widget and Live
/// Activity buttons; seen 23 Nov 2026).
struct MacPlaybackCardButtons: View {
    let state: MacPlaybackActivityAttributes.ContentState
    let size: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Button(intent: ActivityPlayPauseOnMacIntent()) {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: size * 0.52))
                    .frame(width: size, height: size)
                    .contentShape(.rect)
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(state.isPlaying ? "Pause on Mac" : "Play on Mac")
            Button(intent: ActivityNextOnMacIntent()) {
                Image(systemName: "forward.fill")
                    .font(.system(size: size * 0.42))
                    .frame(width: size, height: size)
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
        .tint(MacPlaybackCardInk.primary.opacity(0.9))
        .labelsHidden()
    }

    private var times: some View {
        HStack {
            if state.isPlaying {
                Text(timerInterval: range, countsDown: false)
                Spacer()
                Text("−") + Text(timerInterval: range, countsDown: true)
            } else {
                Text(Self.clock(state.elapsed))
                Spacer()
                Text("−" + Self.clock(max(state.duration - state.elapsed, 0)))
            }
        }
        .font(.system(size: 11, weight: .medium).monospacedDigit())
        .foregroundStyle(MacPlaybackCardInk.tertiary)
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
