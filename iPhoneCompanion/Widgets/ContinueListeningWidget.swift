import AppIntents
import StandByKit
import SwiftUI
import UIKit
import WidgetKit

/// The Continue Listening widget (22 November 2026): the Mac's song as last
/// heard, with Continue on iPhone, or Continue on Mac once the iPhone has it.
/// Modelled on the Music widget. Its picture comes from `WidgetSnapshot`,
/// which the app and the Now Playing extension keep current; the buttons
/// read the Mac afresh, so they're right even when the picture lags.
struct ContinueListeningWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSnapshot.kind, provider: Provider()) { entry in
            ContinueListeningView(entry: entry)
                .containerBackground(for: .widget) { Color(white: 0.13) }
        }
        .configurationDisplayName("Continue Listening")
        .description("What’s playing on your Mac, ready to continue on this iPhone.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> ContinueListeningEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (ContinueListeningEntry) -> Void) {
        completion(context.isPreview && WidgetSnapshot.load() == nil ? .placeholder : current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ContinueListeningEntry>) -> Void) {
        // Reloaded when the song changes; no schedule of its own.
        completion(Timeline(entries: [current()], policy: .never))
    }

    private func current() -> ContinueListeningEntry {
        let snapshot = WidgetSnapshot.load()
        return ContinueListeningEntry(date: Date(), snapshot: snapshot, artwork: ContinueListeningEntry.image(for: snapshot?.artworkID))
    }
}
