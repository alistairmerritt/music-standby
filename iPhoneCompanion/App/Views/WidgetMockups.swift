#if DEBUG
import StandByKit
import SwiftUI
import UIKit

/// EXPERIMENT (22 November 2026): proposed widgets and controls, drawn at
/// their real sizes for review. `-widgetMockups 1|2` shows a page.
/// Nothing here is a real widget yet.
enum WidgetMockups {
    static var page: Int? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let at = arguments.firstIndex(of: "-widgetMockups"), arguments.count > at + 1 else { return nil }
        return Int(arguments[at + 1])
    }
}

private func cover(_ id: String) -> Image {
    MockArtwork.cover(id: "mock-art-\(id)").flatMap(UIImage.init(data:)).map(Image.init(uiImage:)) ?? Image(systemName: "music.note")
}

struct WidgetMockupsView: View {
    let page: Int

    var body: some View {
        ZStack {
            // A wallpaper-ish background, like the Home Screen.
            LinearGradient(colors: [Color(red: 0.36, green: 0.42, blue: 0.55), Color(red: 0.55, green: 0.47, blue: 0.40), Color(red: 0.20, green: 0.22, blue: 0.27)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if page == 1 { homeScreen } else { lockScreenAndControls }
                }
                .padding(.horizontal, 22)
                .padding(.top, 20)
            }
        }
        .environment(\.colorScheme, .dark)
    }

    // MARK: Page 1: Home Screen widgets

    @ViewBuilder private var homeScreen: some View {
        caption("1  Continue Listening · small")
        HStack(spacing: 22) {
            SmallContinueWidget(art: cover("low-sun"), title: "Low Sun", artist: "Drift Hotel", state: .macPlaying)
            SmallContinueWidget(art: cover("rooftop-season"), title: "Rooftop Season", artist: "Remy Saint", state: .onIPhone)
        }
        HStack(spacing: 22) {
            label("Mac playing")
            label("After Continue on iPhone")
        }
        HStack(spacing: 22) {
            SmallContinueWidget(art: cover("small-hours"), title: "Small Hours", artist: "Fen Lights", state: .macPaused)
            SmallContinueWidget(art: nil, title: nil, artist: nil, state: .nothing)
        }
        HStack(spacing: 22) {
            label("Mac paused")
            label("Nothing playing")
        }
        caption("1  Continue Listening · medium")
        MediumContinueWidget(art: cover("ticket-hall"), title: "Ticket Hall", artist: "Polly Atlas", album: "Concourse")
    }

    // MARK: Page 2: Lock Screen and Control Centre

    @ViewBuilder private var lockScreenAndControls: some View {
        caption("2  Lock Screen controls (bottom corners)")
        HStack {
            LockCornerControl(symbol: "iphone", fallback: "iphone")
            Spacer()
            LockCornerControl(symbol: "lock.iphone", fallback: "lock.iphone")
        }
        .padding(.horizontal, 30)
        HStack {
            label("Continue on iPhone")
            Spacer()
            label("Show on Lock Screen")
        }
        .padding(.horizontal, 6)

        caption("2  Control Centre")
        HStack(alignment: .top, spacing: 16) {
            ControlCentreButton(symbol: "iphone", title: "Continue on iPhone")
            ControlCentreButton(symbol: "laptopcomputer", title: "Continue on Mac")
            ControlCentreButton(symbol: "lock.iphone", title: "Show on Lock Screen")
        }

        caption("3  Lock Screen widget")
        HStack(spacing: 16) {
            RectangularLockWidget()
            CircularLockWidget()
        }
    }

    // MARK: Helpers

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.8)).padding(.top, 8)
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.caption2).foregroundStyle(.white.opacity(0.7)).frame(width: 170)
    }
}

// MARK: - Widgets

private enum ContinueState { case macPlaying, macPaused, onIPhone, nothing }

/// Modelled on the Music widget: artwork top left, the app's mark top right,
/// title and artist, one capsule button.
private struct SmallContinueWidget: View {
    let art: Image?
    let title: String?
    let artist: String?
    let state: ContinueState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                artwork.frame(width: 62, height: 62)
                Spacer()
                Image(systemName: "laptopcomputer").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
            }
            Spacer(minLength: 6)
            if let title, let artist {
                Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text(subtitle(artist)).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text("Nothing playing").font(.system(size: 15, weight: .semibold))
                Text("on MacBook Pro").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            button
        }
        .padding(14)
        .frame(width: 170, height: 170)
        .background(Color(white: 0.17), in: .rect(cornerRadius: 24, style: .continuous))
    }

    private func subtitle(_ artist: String) -> String {
        switch state {
        case .macPaused: "Paused on Mac"
        case .onIPhone: "On iPhone"
        default: artist
        }
    }

    @ViewBuilder private var artwork: some View {
        if let art {
            art.resizable().scaledToFill().clipShape(.rect(cornerRadius: 9, style: .continuous))
                .saturation(state == .onIPhone ? 0 : 1).opacity(state == .onIPhone ? 0.6 : 1)
        } else {
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.12))
                .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
        }
    }

    @ViewBuilder private var button: some View {
        switch state {
        case .macPlaying, .macPaused:
            capsule("iphone", "Continue")
        case .onIPhone:
            capsule("laptopcomputer", "To Mac")
        case .nothing:
            Color.clear.frame(height: 34)
        }
    }

    private func capsule(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 15, weight: .semibold))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.white.opacity(0.16), in: .capsule)
    }
}

private struct MediumContinueWidget: View {
    let art: Image
    let title: String
    let artist: String
    let album: String

    var body: some View {
        HStack(spacing: 14) {
            art.resizable().scaledToFill().frame(width: 142, height: 142).clipShape(.rect(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Label("MacBook Pro", systemImage: "laptopcomputer").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.bottom, 4)
                Text(title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                Text(artist).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
                Label("Continue on iPhone", systemImage: "iphone")
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1).fixedSize()
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.white.opacity(0.16), in: .capsule)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: 364, height: 170)
        .background(Color(white: 0.17), in: .rect(cornerRadius: 24, style: .continuous))
    }
}

// MARK: - Controls and Lock Screen

private struct LockCornerControl: View {
    let symbol: String
    let fallback: String

    var body: some View {
        Image(systemName: UIImage(systemName: symbol) != nil ? symbol : fallback)
            .font(.system(size: 20, weight: .medium))
            .frame(width: 50, height: 50)
            .background(.ultraThinMaterial, in: .circle)
    }
}

private struct ControlCentreButton: View {
    let symbol: String
    let title: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .medium))
                .frame(width: 64, height: 64)
                .background(.ultraThinMaterial, in: .circle)
            Text(title).font(.system(size: 11, weight: .medium)).multilineTextAlignment(.center).frame(width: 80)
        }
    }
}

private struct RectangularLockWidget: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Label("MacBook Pro", systemImage: "laptopcomputer").font(.system(size: 12, weight: .semibold))
            Text("Low Sun").font(.system(size: 15, weight: .semibold)).lineLimit(1)
            Text("Drift Hotel").font(.system(size: 13)).opacity(0.8).lineLimit(1)
        }
        .frame(width: 160, height: 72, alignment: .leading)
        .padding(.horizontal, 10)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 14))
    }
}

private struct CircularLockWidget: View {
    var body: some View {
        Image(systemName: "iphone")
            .font(.system(size: 22, weight: .semibold))
            .frame(width: 72, height: 72)
            .background(.ultraThinMaterial, in: .circle)
    }
}
#endif
