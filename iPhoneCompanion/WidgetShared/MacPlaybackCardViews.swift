import AppIntents
import CoreImage
import CoreImage.CIFilterBuiltins
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

    /// The card's background: the cover, heavily blurred, in the spirit of
    /// Home's (`HomeBackground`: saturation 1.25, brightness −0.12, then a
    /// black wash). Made here because a Live Activity can't blur a view
    /// reliably, and kept small: it's only colour (Alistair, 23 Nov 2026).
    static func backdrop(from cover: UIImage?) -> UIImage? {
        guard let cover, let input = CIImage(image: cover) else { return nil }
        let size: CGFloat = 96
        let scaled = input.transformed(by: CGAffineTransform(scaleX: size / input.extent.width, y: size / input.extent.height))
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = scaled.clampedToExtent()
        blur.radius = 14
        let tone = CIFilter.colorControls()
        tone.inputImage = blur.outputImage
        tone.saturation = 1.25
        tone.brightness = -0.12
        guard let output = tone.outputImage?.cropped(to: CGRect(x: 0, y: 0, width: size, height: size)),
              let cg = CIContext(options: [.useSoftwareRenderer: false]).createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// The Lock Screen and StandBy card: the Mac's song, its progress, and
/// play/pause and next.
struct MacPlaybackCardView: View {
    let attributes: MacPlaybackActivityAttributes
    let state: MacPlaybackActivityAttributes.ContentState
    let artwork: UIImage?
    /// The blurred cover behind the card; nil until the artwork is cached,
    /// when iOS's own background shows instead.
    let backdrop: UIImage?

    init(attributes: MacPlaybackActivityAttributes, state: MacPlaybackActivityAttributes.ContentState) {
        self.attributes = attributes
        self.state = state
        artwork = MacPlaybackCardArtwork.image(for: state.artworkID)
        backdrop = MacPlaybackCardArtwork.backdrop(from: artwork)
    }

    var body: some View {
        if let backdrop {
            content
                .background {
                    ZStack {
                        Image(uiImage: backdrop).resizable().scaledToFill()
                        Color.black.opacity(0.35)
                    }
                }
                // The square cover fills a wide card: keep it inside.
                .clipped()
                // Always dark under the artwork, as on Home: white type.
                .environment(\.colorScheme, .dark)
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                MacPlaybackCardCover(image: artwork, size: 56)
                VStack(alignment: .leading, spacing: 1) {
                    Label(attributes.macName, systemImage: "laptopcomputer")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
                        .padding(.bottom, 2)
                    Text(state.hasSong ? state.title : "Nothing playing").font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    if state.hasSong {
                        Text(state.artist).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                MacPlaybackCardButtons(state: state, size: 44)
            }
            MacPlaybackCardProgress(state: state)
            // The tap opens Second Chair, which brings the Mac's player back
            // (scrubber, volume, Control Centre) and ends the card.
            Text("Tap for the full player")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, -4)
        }
        .foregroundStyle(.primary)
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
                Rectangle().fill(.quaternary).overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
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
        .foregroundStyle(.primary)
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
        .tint(.primary)
        .labelsHidden()
    }
}
