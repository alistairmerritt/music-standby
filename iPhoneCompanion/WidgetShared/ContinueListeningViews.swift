import StandByKit
import SwiftUI
import UIKit
import WidgetKit

// The Continue Listening widget's views, shared so the app can draw them
// for review (`-widgetPreview`, development builds). 22 November 2026.

struct ContinueListeningEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
    let artwork: UIImage?

    static let placeholder = ContinueListeningEntry(
        date: Date(),
        snapshot: WidgetSnapshot(macName: "MacBook Pro", title: "Low Sun", artist: "Drift Hotel", album: "Breakwater",
                                 artworkID: "mock-art-low-sun", macPlaying: true),
        artwork: Self.image(for: "mock-art-low-sun"))

    static func image(for id: String?) -> UIImage? {
        guard let id else { return nil }
        let data = MockArtwork.cover(id: id) ?? ArtworkStore(container: SharedContainer.appGroup()).load(id: id)
        // Widgets have little memory: a small copy is plenty for 140 points.
        return data.flatMap(UIImage.init(data:))?.preparingThumbnail(of: CGSize(width: 300, height: 300))
    }
}

struct ContinueListeningView: View {
    let entry: ContinueListeningEntry
    /// Set when drawn outside a widget, for review.
    var familyOverride: WidgetFamily?
    @Environment(\.widgetFamily) private var environmentFamily
    private var family: WidgetFamily { familyOverride ?? environmentFamily }

    private var snapshot: WidgetSnapshot? { entry.snapshot }
    private var hasSong: Bool { snapshot?.title != nil }
    private var onIPhone: Bool { snapshot?.onIPhone ?? false }

    var body: some View {
        if family == .systemMedium { medium } else { small }
    }

    // MARK: Small

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                artwork.frame(width: 60, height: 60)
                Spacer()
                Image(systemName: "laptopcomputer").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
            }
            Spacer(minLength: 4)
            titleLines(titleSize: 15, subtitleSize: 13)
            Spacer(minLength: 6)
            if hasSong { button(short: true) }
        }
    }

    // MARK: Medium

    private var medium: some View {
        HStack(spacing: 14) {
            artwork.frame(width: 112, height: 112)
            VStack(alignment: .leading, spacing: 2) {
                Label(snapshot?.macName ?? "Your Mac", systemImage: "laptopcomputer")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
                    .padding(.bottom, 4)
                titleLines(titleSize: 16, subtitleSize: 14)
                Spacer(minLength: 6)
                if hasSong { button(short: false) }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Parts

    @ViewBuilder private func titleLines(titleSize: CGFloat, subtitleSize: CGFloat) -> some View {
        if let snapshot, let title = snapshot.title {
            Text(title).font(.system(size: titleSize, weight: .semibold)).lineLimit(1)
            Text(subtitle(snapshot)).font(.system(size: subtitleSize)).foregroundStyle(.secondary).lineLimit(1)
        } else {
            Text("Nothing playing").font(.system(size: titleSize, weight: .semibold)).lineLimit(1)
            Text(snapshot.map { "on \($0.macName)" } ?? "Open Second Chair to pair").font(.system(size: subtitleSize)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func subtitle(_ snapshot: WidgetSnapshot) -> String {
        if snapshot.onIPhone { return "On iPhone" }
        if !snapshot.macPlaying { return "Paused on Mac" }
        return snapshot.artist ?? ""
    }

    @ViewBuilder private var artwork: some View {
        Group {
            if let image = entry.artwork {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(.white.opacity(0.12)).overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
            }
        }
        .clipShape(.rect(cornerRadius: family == .systemMedium ? 12 : 9, style: .continuous))
        // Greyed while the iPhone has the music, as in the app.
        .saturation(onIPhone ? 0 : 1)
        .opacity(onIPhone ? 0.6 : 1)
    }

    @ViewBuilder private func button(short: Bool) -> some View {
        if onIPhone {
            Button(intent: WidgetContinueOnMacIntent()) {
                Label(short ? "To Mac" : "Continue on Mac", systemImage: "laptopcomputer")
            }
            .modifier(CapsuleButton())
        } else {
            Button(intent: WidgetContinueOnIPhoneIntent()) {
                Label(short ? "Continue" : "Continue on iPhone", systemImage: "iphone")
            }
            .modifier(CapsuleButton())
        }
    }
}

private struct CapsuleButton: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 14, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .buttonStyle(.plain)
            .padding(.horizontal, 13).padding(.vertical, 8)
            .background(.white.opacity(0.16), in: .capsule)
            .foregroundStyle(.white)
    }
}
