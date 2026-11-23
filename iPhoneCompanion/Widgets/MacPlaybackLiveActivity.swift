import ActivityKit
import SwiftUI
import WidgetKit

/// The Live Activity card (experiment, 23 November 2026): Lock Screen,
/// StandBy and the Dynamic Island. Tapping anywhere but the buttons opens
/// Second Chair, which brings the Mac's player back and ends the card.
struct MacPlaybackLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MacPlaybackActivityAttributes.self) { context in
            // iOS's own background (Alistair, 23 Nov): light or dark with the
            // phone, so the card's colours are the system's, not white.
            MacPlaybackCardView(attributes: context.attributes, state: context.state)
        } dynamicIsland: { context in
            let state = context.state
            let artwork = MacPlaybackCardArtwork.image(for: state.artworkID, pixels: 120)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    MacPlaybackCardCover(image: artwork, size: 48).padding(.leading, 4)
                }
                // No buttons for now (see MacPlaybackCardView); the Mac instead.
                DynamicIslandExpandedRegion(.trailing) {
                    Image(systemName: "laptopcomputer").font(.system(size: 17)).foregroundStyle(.secondary).padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(state.hasSong ? state.title : "Nothing playing").font(.system(size: 15, weight: .semibold)).lineLimit(1)
                        Text(state.hasSong ? state.artist : context.attributes.macName).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 4) {
                        Text("Show in Now Playing")
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                    }
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 6).padding(.top, 4)
                }
            } compactLeading: {
                MacPlaybackCardCover(image: artwork, size: 22)
            } compactTrailing: {
                Image(systemName: state.isPlaying ? "waveform" : "pause.fill")
                    .symbolEffect(.variableColor.iterative, isActive: state.isPlaying)
                    .foregroundStyle(.white)
            } minimal: {
                MacPlaybackCardCover(image: artwork, size: 22)
            }
        }
    }
}
