import ActivityKit
import SwiftUI
import WidgetKit

/// The Live Activity card (experiment, 23 November 2026): Lock Screen,
/// StandBy and the Dynamic Island. Tapping anywhere but the buttons opens
/// Second Chair, which brings the Mac's player back and ends the card.
struct MacPlaybackLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MacPlaybackActivityAttributes.self) { context in
            MacPlaybackCardView(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(Color(red: 0.08, green: 0.07, blue: 0.19).opacity(0.82))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            let artwork = MacPlaybackCardArtwork.image(for: state.artworkID, pixels: 120)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    MacPlaybackCardCover(image: artwork, size: 48).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    MacPlaybackCardButtons(state: state, size: 40)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(state.hasSong ? state.title : "Nothing playing").font(.system(size: 15, weight: .semibold)).lineLimit(1)
                        Text(state.hasSong ? state.artist : context.attributes.macName).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    MacPlaybackCardProgress(state: state).padding(.horizontal, 4).padding(.top, 4)
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
