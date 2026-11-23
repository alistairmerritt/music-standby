import StandByKit
import SwiftUI
import WidgetKit

#if DEBUG
/// `-widgetPreview`: the real widget view, in each state, at widget sizes.
struct WidgetPreviewPage: View {
    static var isOn: Bool { ProcessInfo.processInfo.arguments.contains("-widgetPreview") }

    private func entry(_ id: String?, _ title: String?, _ artist: String?, playing: Bool, onIPhone: Bool) -> ContinueListeningEntry {
        ContinueListeningEntry(date: Date(),
                               snapshot: WidgetSnapshot(macName: "MacBook Pro", title: title, artist: artist, artworkID: id.map { "mock-art-\($0)" },
                                                        macPlaying: playing, onIPhone: onIPhone),
                               artwork: ContinueListeningEntry.image(for: id.map { "mock-art-\($0)" }))
    }

    private func tile(_ entry: ContinueListeningEntry, _ family: WidgetFamily) -> some View {
        ContinueListeningView(entry: entry, familyOverride: family)
            .padding(16)
            .frame(width: family == .systemMedium ? 364 : 170, height: 170)
            .background(Color(white: 0.13), in: .rect(cornerRadius: 24, style: .continuous))
            .environment(\.colorScheme, .dark)
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.36, green: 0.42, blue: 0.55), Color(red: 0.55, green: 0.47, blue: 0.40)],
                           startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
            VStack(spacing: 20) {
                HStack(spacing: 22) {
                    tile(entry("low-sun", "Low Sun", "Drift Hotel", playing: true, onIPhone: false), .systemSmall)
                    tile(entry("rooftop-season", "Rooftop Season", "Remy Saint", playing: false, onIPhone: true), .systemSmall)
                }
                HStack(spacing: 22) {
                    tile(entry("small-hours", "Small Hours", "Fen Lights", playing: false, onIPhone: false), .systemSmall)
                    tile(entry(nil, nil, nil, playing: false, onIPhone: false), .systemSmall)
                }
                tile(entry("ticket-hall", "Ticket Hall", "Polly Atlas", playing: true, onIPhone: false), .systemMedium)
                tile(entry("tidewater", "Tidewater", "Brennan & Hale", playing: false, onIPhone: true), .systemMedium)
            }
        }
    }
}
#endif
