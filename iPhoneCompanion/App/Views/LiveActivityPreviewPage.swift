import SwiftUI

#if DEBUG
/// `-liveActivityPreview`: the Live Activity card's real views (experiment),
/// drawn roughly as iOS places them: the card with nothing behind it on a
/// dark and a pale wallpaper, and the Dynamic Island's compact, minimal and
/// expanded forms. The Simulator's screenshots don't show a real card on the
/// Lock Screen or in the island.
struct LiveActivityPreviewPage: View {
    static var isOn: Bool { ProcessInfo.processInfo.arguments.contains("-liveActivityPreview") }

    private let attributes = MacPlaybackActivityAttributes(activityID: "preview", macName: "MacBook Pro")

    private func state(_ title: String, _ artist: String, _ art: String, playing: Bool, elapsed: Double, duration: Double) -> MacPlaybackActivityAttributes.ContentState {
        .init(title: title, artist: artist, album: "", artworkID: art.isEmpty ? "" : "mock-art-\(art)", isPlaying: playing, elapsed: elapsed,
              capturedAt: Date().timeIntervalSince1970, duration: duration, canGoNext: true)
    }

    var body: some View {
        let lowSun = state("Low Sun", "Drift Hotel", "low-sun", playing: true, elapsed: 75, duration: 214)
        let ticketHall = state("Ticket Hall", "Polly Atlas", "ticket-hall", playing: false, elapsed: 131, duration: 198)
        let rooftop = state("Rooftop Season", "Remy Saint", "rooftop-season", playing: true, elapsed: 20, duration: 228)
        VStack(spacing: 0) {
            // A dark wallpaper, with the island.
            VStack(spacing: 12) {
                HStack(spacing: 14) {
                    compactIsland(lowSun)
                    minimalIsland(lowSun)
                }
                expandedIsland(lowSun)
                MacPlaybackCardView(attributes: attributes, state: lowSun)
                    .background(.white.opacity(0.06), in: .rect(cornerRadius: 24, style: .continuous))   // iOS's faint plate, roughly
                MacPlaybackCardView(attributes: attributes, state: ticketHall)
                    .background(.white.opacity(0.06), in: .rect(cornerRadius: 24, style: .continuous))
            }
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 16)
            .frame(maxWidth: .infinity)
            .background(LinearGradient(colors: [Color(red: 0.13, green: 0.15, blue: 0.27), Color(red: 0.33, green: 0.24, blue: 0.27)],
                                       startPoint: .top, endPoint: .bottom))
            // A pale wallpaper: the hardest case for a card with no fill.
            VStack(spacing: 12) {
                MacPlaybackCardView(attributes: attributes, state: rooftop)
                    .background(.white.opacity(0.06), in: .rect(cornerRadius: 24, style: .continuous))
                MacPlaybackCardView(attributes: attributes, state: state("Small Hours", "Fen Lights", "", playing: true, elapsed: 40, duration: 252))
                    .background(.white.opacity(0.06), in: .rect(cornerRadius: 24, style: .continuous))
            }
            .padding(.horizontal, 12).padding(.vertical, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(LinearGradient(colors: [Color(red: 0.86, green: 0.80, blue: 0.72), Color(red: 0.62, green: 0.70, blue: 0.78)],
                                       startPoint: .top, endPoint: .bottom))
        }
        .ignoresSafeArea(edges: .bottom)
        .environment(\.colorScheme, .dark)
    }

    private func cover(_ state: MacPlaybackActivityAttributes.ContentState, _ size: CGFloat) -> some View {
        MacPlaybackCardCover(image: MacPlaybackCardArtwork.image(for: state.artworkID, pixels: 156), size: size)
    }

    private func compactIsland(_ state: MacPlaybackActivityAttributes.ContentState) -> some View {
        HStack {
            cover(state, 22)
            Spacer()
            Image(systemName: "waveform").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .frame(width: 236, height: 37)
        .background(.black, in: .capsule)
    }

    private func minimalIsland(_ state: MacPlaybackActivityAttributes.ContentState) -> some View {
        cover(state, 22).frame(width: 37, height: 37).background(.black, in: .circle)
    }

    private func expandedIsland(_ state: MacPlaybackActivityAttributes.ContentState) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                cover(state, 52)
                MacPlaybackCardTitles(attributes: attributes, state: state, titleSize: 15)
                    .frame(maxWidth: .infinity, alignment: .leading)
                MacPlaybackCardButtons(state: state, size: 38)
            }
            MacPlaybackCardProgress(state: state).padding(.horizontal, 4)
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .background(.black, in: .rect(cornerRadius: 44, style: .continuous))
    }
}
#endif
