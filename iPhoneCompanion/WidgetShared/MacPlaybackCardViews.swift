import AppIntents
import StandByKit
import SwiftUI
import UIKit

// The Live Activity card's views (experiment, 23 November 2026). In the
// shared folder, so development builds can draw them in the app too.

/// The card's artwork: from the cache the Now Playing extension fills, or the
/// demo's bundled covers. A Live Activity can't use the network, and its
/// images may be no bigger than they're drawn, so it's read small.
enum MacPlaybackCardArtwork {
    static func image(for id: String, pixels: CGFloat = 168) -> UIImage? {
        guard !id.isEmpty else { return nil }
        let data = MockArtwork.cover(id: id) ?? ArtworkStore(container: SharedContainer.appGroup()).load(id: id)
        return data.flatMap(UIImage.init(data:))?.preparingThumbnail(of: CGSize(width: pixels, height: pixels))
    }
}

/// The Lock Screen and StandBy card: the Mac's song, its progress, and
/// play/pause and next.
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
            HStack(spacing: 12) {
                MacPlaybackCardCover(image: artwork, size: 56)
                VStack(alignment: .leading, spacing: 1) {
                    Label(attributes.macName, systemImage: "laptopcomputer")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                        .padding(.bottom, 2)
                    Text(state.hasSong ? state.title : "Nothing playing").font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    if state.hasSong {
                        Text(state.artist).font(.system(size: 14)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                MacPlaybackCardButtons(state: state, size: 44)
            }
            MacPlaybackCardProgress(state: state)
        }
        .foregroundStyle(.white)
        .padding(16)
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
                Rectangle().fill(.white.opacity(0.12)).overlay(Image(systemName: "music.note").foregroundStyle(.white.opacity(0.6)))
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: size * 0.16, style: .continuous))
    }
}

/// Play/pause and next. Big targets: a card's buttons are easy to miss.
struct MacPlaybackCardButtons: View {
    let state: MacPlaybackActivityAttributes.ContentState
    let size: CGFloat

    var body: some View {
        HStack(spacing: 4) {
            Button(intent: ActivityPlayPauseOnMacIntent()) {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .frame(width: size, height: size)
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(state.isPlaying ? "Pause on Mac" : "Play on Mac")
            if state.canGoNext {
                Button(intent: ActivityNextOnMacIntent()) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .frame(width: size, height: size)
                }
                .accessibilityLabel("Next Song on Mac")
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }
}

/// Runs by itself while playing (the system draws it from the start and end
/// times), and holds still while paused.
struct MacPlaybackCardProgress: View {
    let state: MacPlaybackActivityAttributes.ContentState

    var body: some View {
        Group {
            if state.isPlaying, state.duration > 0 {
                ProgressView(timerInterval: state.startedAt...state.startedAt.addingTimeInterval(state.duration), countsDown: false) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
            } else {
                ProgressView(value: state.progress)
            }
        }
        .progressViewStyle(.linear)
        .tint(.white)
        .labelsHidden()
    }
}
