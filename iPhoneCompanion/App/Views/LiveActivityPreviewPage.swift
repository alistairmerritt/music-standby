import SwiftUI

#if DEBUG
/// `-liveActivityPreview`: the Live Activity card's real views (experiment),
/// drawn on a Lock Screen-like page: the card playing and paused, and the
/// Dynamic Island's expanded and compact forms. The Simulator's screenshots
/// don't show a real card on the Lock Screen or in the island.
struct LiveActivityPreviewPage: View {
    static var isOn: Bool { ProcessInfo.processInfo.arguments.contains("-liveActivityPreview") }

    private let attributes = MacPlaybackActivityAttributes(activityID: "preview", macName: "MacBook Pro")

    private func state(_ title: String, _ artist: String, _ art: String, playing: Bool, elapsed: Double, duration: Double) -> MacPlaybackActivityAttributes.ContentState {
        .init(title: title, artist: artist, album: "", artworkID: "mock-art-\(art)", isPlaying: playing, elapsed: elapsed,
              capturedAt: Date().timeIntervalSince1970, duration: duration, canGoNext: true)
    }

    var body: some View {
        let lowSun = state("Low Sun", "Drift Hotel", "low-sun", playing: true, elapsed: 75, duration: 214)
        let paused = state("Ticket Hall", "Polly Atlas", "ticket-hall", playing: false, elapsed: 131, duration: 198)
        ZStack {
            LinearGradient(colors: [Color(red: 0.20, green: 0.22, blue: 0.36), Color(red: 0.47, green: 0.36, blue: 0.31)],
                           startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            VStack(spacing: 14) {
                island(compact: lowSun)
                expandedIsland(lowSun).padding(.bottom, 6)
                Text("9:41").font(.system(size: 88, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.9))
                Spacer().frame(height: 4)
                lockScreenCard(lowSun)
                lockScreenCard(paused)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
        .environment(\.colorScheme, .dark)
    }

    /// As iOS draws it: the card on a tinted, translucent plate.
    private func lockScreenCard(_ state: MacPlaybackActivityAttributes.ContentState) -> some View {
        MacPlaybackCardView(attributes: attributes, state: state)
            .background(Color(red: 0.08, green: 0.07, blue: 0.19).opacity(0.82), in: .rect(cornerRadius: 24, style: .continuous))
    }

    private func island(compact state: MacPlaybackActivityAttributes.ContentState) -> some View {
        HStack {
            MacPlaybackCardCover(image: MacPlaybackCardArtwork.image(for: state.artworkID, pixels: 120), size: 22)
            Spacer()
            Image(systemName: state.isPlaying ? "waveform" : "pause.fill").foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .frame(width: 250, height: 37)
        .background(.black, in: .capsule)
    }

    private func expandedIsland(_ state: MacPlaybackActivityAttributes.ContentState) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                MacPlaybackCardCover(image: MacPlaybackCardArtwork.image(for: state.artworkID, pixels: 120), size: 48)
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text(state.artist).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                MacPlaybackCardButtons(state: state, size: 40)
            }
            MacPlaybackCardProgress(state: state).padding(.horizontal, 4)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18).padding(.vertical, 16)
        .background(.black, in: .rect(cornerRadius: 44, style: .continuous))
    }
}
#endif
