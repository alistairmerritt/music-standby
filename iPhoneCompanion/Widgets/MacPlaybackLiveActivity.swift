import ActivityKit
import SwiftUI
import WidgetKit

/// The Live Activity card (experiment; redesigned 24 November 2026): Lock
/// Screen, StandBy and the Dynamic Island. A fallback for the Mac's Now
/// Playing player, not a second one. Tapping anywhere but the buttons opens
/// Second Chair, which asks iOS for the Mac's player and, once it's granted,
/// ends the card (`LiveActivityController.endAll`).
struct MacPlaybackLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MacPlaybackActivityAttributes.self) { context in
            MacPlaybackCardView(attributes: context.attributes, state: context.state)
                // No fill: the content floats on the Lock Screen, which does
                // the visual work. (A clear tint is the nearest ActivityKit
                // gets to "no background"; iOS may still draw its own faint
                // plate behind it.)
                .activityBackgroundTint(.clear)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            let artwork = MacPlaybackCardArtwork.image(for: state.artworkID, pixels: 156)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    // No artwork cached: no cover, rather than an empty box.
                    if let artwork {
                        MacPlaybackCardCover(image: artwork, size: 52)
                            .padding(.leading, 2)
                            .frame(maxHeight: .infinity, alignment: .center)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    MacPlaybackCardTitles(attributes: context.attributes, state: state, titleSize: 15)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    MacPlaybackCardButtons(state: state, glyph: 24)
                        .frame(maxHeight: .infinity, alignment: .center)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    MacPlaybackCardProgress(state: state)
                        .padding(.horizontal, 4)
                        .padding(.top, 6)
                }
            } compactLeading: {
                islandMark(artwork)
            } compactTrailing: {
                Image(systemName: state.isPlaying ? "waveform" : "pause.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .symbolEffect(.variableColor.iterative, isActive: state.isPlaying)
                    .foregroundStyle(.white)
            } minimal: {
                islandMark(artwork)
            }
            .keylineTint(.white.opacity(0.4))
        }
    }

    /// The compact and minimal island's mark: the cover, or a note without one.
    @ViewBuilder private func islandMark(_ artwork: UIImage?) -> some View {
        if let artwork {
            MacPlaybackCardCover(image: artwork, size: 22)
        } else {
            Image(systemName: "music.note").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
        }
    }
}
