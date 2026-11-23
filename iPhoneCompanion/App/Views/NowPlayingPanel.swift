import os
import StandByKit
import SwiftUI

private let seekLog = Logger(subsystem: "com.alistairmerritt.MusicStandBy", category: "seekbar")

/// Where the Mac's song stands, for the panel's top label and its controls.
enum NowPlayingMode: Equatable {
    /// The Mac's state is live: the full remote.
    case live
    /// Apple Music on this iPhone plays the Mac's song, as after Continue on
    /// iPhone. The Mac is paused, so its controls would mislead: hidden.
    case onIPhone
    /// Apple Music on this iPhone plays a different song. The Mac's song,
    /// paused, with the remote as usual.
    case iPhonePlaysOther(String?)
    /// The Mac can't be reached: the last song, without controls.
    case lastKnown
}

/// The Mac's song and the remote, on Home. No card: the artwork gives it a
/// shape (21 November 2026 redesign).
struct NowPlayingPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.openURL) private var openURL
    let attributes: MacPlaybackAttributes?
    let mode: NowPlayingMode

    var body: some View {
        if let attributes, let track = attributes.track {
            VStack(alignment: .leading, spacing: 20) {
                header(track: track)
                switch mode {
                case .live, .iPhonePlaysOther:
                    VStack(spacing: 14) {
                        SeekBar(attributes: attributes, duration: track.duration) { seconds in
                            Task { await model.seek(to: seconds) }
                        }
                        TransportControls(isPlaying: attributes.isPlaying) { kind in
                            Task { await model.send(kind) }
                        }
                        if let volume = attributes.volume {
                            VolumeRow(level: volume) { level in
                                Task { await model.setVolume(level) }
                            }
                        }
                    }
                    // The Mac's paused song while the iPhone plays another: its
                    // controls aren't what's playing, so they step back (as
                    // before the redesign, 17 November 2026).
                    .disabled(dimsMacSong)
                    .opacity(dimsMacSong ? 0.4 : 1)
                case .onIPhone:
                    // The song's controls are in Apple Music now, so the way
                    // there takes the remote's place, as Home's one accent;
                    // Continue on Mac steps back (Alistair, 23 November 2026).
                    VStack(spacing: 10) {
                        Button {
                            openURL(SystemMusicPhonePlayer.appURL)
                        } label: {
                            Label("Open Apple Music", systemImage: "arrow.up.forward.app")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        Text("Paused on Mac at \(Duration.seconds(attributes.elapsed(at: Date())), format: .time(pattern: .minuteSecond))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                case .lastKnown:
                    EmptyView()
                }
            }
        } else {
            emptyState
        }
    }

    @ViewBuilder private func header(track: SessionTrack) -> some View {
        let stacked = typeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
                             : AnyLayout(HStackLayout(alignment: .center, spacing: 16))
        layout {
            Artwork(image: model.artwork, size: stacked ? 180 : 120)
                // Greyed while the iPhone plays and the Mac is paused: this is
                // the Mac's song, not what's playing (Alistair, 21 November 2026).
                .saturation(dimsMacSong ? 0 : 1)
                .opacity(dimsMacSong ? 0.5 : 1)
            VStack(alignment: .leading, spacing: 4) {
                if let label { label }
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                    Text(track.artist)
                        .font(.body)
                        .lineLimit(1)
                    Text(track.album)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .opacity(dimsMacSong ? 0.45 : 1)
            }
            .foregroundStyle(mode == .lastKnown ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    /// The iPhone plays while the Mac is paused: the Mac's song greys out.
    private var dimsMacSong: Bool {
        switch mode {
        case .onIPhone, .iPhonePlaysOther: true
        case .live, .lastKnown: false
        }
    }

    /// A small capsule above the title, saying where the music is.
    private var label: StatusCapsule? {
        switch mode {
        case .live: nil
        case .onIPhone: StatusCapsule(symbol: "iphone", text: "Playing on iPhone")
        case .iPhonePlaysOther(let title):
            StatusCapsule(symbol: "iphone", text: title.map { "iPhone is playing “\($0)”" } ?? "iPhone is playing")
        case .lastKnown: StatusCapsule(symbol: "clock", text: "Last played on Mac")
        }
    }

    private var emptyState: some View {
        HStack(alignment: .center, spacing: 16) {
            Artwork(image: nil, size: 120)
            VStack(alignment: .leading, spacing: 4) {
                Text("Nothing playing on your Mac.")
                    .font(.title3.weight(.semibold))
                Text("Play something in Music and it’ll appear here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

struct StatusCapsule: View {
    let symbol: String
    let text: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.fill.tertiary, in: .capsule)
            .padding(.bottom, 2)
    }
}

private struct Artwork: View {
    let image: CGImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: size * 0.3))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: 10))
        // A hairline, so dark artwork keeps its edge on a dark background.
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5) }
        .accessibilityHidden(true)
    }
}

/// The progress bar, draggable. While dragging it shows the finger's position;
/// when the drag ends the Mac is asked to seek there, and the bar goes back to
/// following the Mac's own state until the result arrives.
///
/// The end of a drag is taken from `onEditingChanged(false)` **or** from the
/// values going quiet for `settle`: on an iPhone (12 Nov 2026) a drag on this
/// slider reported its start and every value but never its end, with or
/// without the clock running, while the volume slider below always did. The
/// clock also pauses during a drag.
///
/// The 21 November 2026 redesign changed only its look (neutral tint,
/// remaining time on the right). Its logic is as it was.
struct SeekBar: View {
    let attributes: MacPlaybackAttributes
    let duration: TimeInterval
    let onSeek: (TimeInterval) -> Void
    @State private var dragging = false
    @State private var dragValue: TimeInterval = 0
    @State private var now = Date()
    @State private var settling: Task<Void, Never>?
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private static let settle: Duration = .milliseconds(600)

    var body: some View {
        let elapsed = dragging ? dragValue : attributes.elapsed(at: now)
        VStack(spacing: 2) {
            Slider(
                value: Binding(get: { elapsed }, set: { value in
                    dragValue = value
                    if !dragging { dragging = true }
                    settling?.cancel()
                    settling = Task { @MainActor in
                        try? await Task.sleep(for: Self.settle)
                        guard !Task.isCancelled else { return }
                        finishDrag()
                    }
                }),
                in: 0...max(duration, 1),
                onEditingChanged: { editing in
                    if editing {
                        dragValue = elapsed
                        dragging = true
                    } else {
                        settling?.cancel()
                        finishDrag()
                    }
                }
            )
            .tint(.primary)
            .disabled(duration <= 0)
            .accessibilityLabel("Position in the song")
            HStack {
                Text(Duration.seconds(elapsed), format: .time(pattern: .minuteSecond))
                Spacer()
                Text("−") + Text(Duration.seconds(max(0, duration - elapsed)), format: .time(pattern: .minuteSecond))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
        .onReceive(clock) { if !dragging { now = $0 } }
    }

    private func finishDrag() {
        guard dragging else { return }
        seekLog.debug("Seek bar drag ended, seeking to \(dragValue, privacy: .public)")
        dragging = false
        now = Date()
        onSeek(dragValue)
    }
}

/// Music's own volume on the Mac. Sent once when the drag ends. Quieter
/// than the transport: secondary tint, small glyphs.
struct VolumeRow: View {
    let level: Double
    let onChange: (Double) -> Void
    @State private var dragging = false
    @State private var dragValue = 0.0

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill").font(.caption).foregroundStyle(.secondary)
            Slider(
                value: Binding(get: { dragging ? dragValue : level }, set: { dragValue = $0 }),
                in: 0...1,
                onEditingChanged: { editing in
                    if editing {
                        dragValue = level
                    } else {
                        onChange(dragValue)
                    }
                    dragging = editing
                }
            )
            .tint(.secondary)
            Image(systemName: "speaker.wave.3.fill").font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Volume on your Mac")
    }
}

/// Previous, play or pause, next. Neutral, not tinted: the accent is kept
/// for Continue Listening.
struct TransportControls: View {
    let isPlaying: Bool
    let action: (CommandKind) -> Void

    var body: some View {
        HStack(spacing: 0) {
            button("backward.fill", "Previous", .previous, size: 26)
            button(isPlaying ? "pause.fill" : "play.fill", isPlaying ? "Pause" : "Play", isPlaying ? .pause : .play, size: 40)
            button("forward.fill", "Next", .next, size: 26)
        }
        .foregroundStyle(.primary)
    }

    private func button(_ symbol: String, _ label: String, _ kind: CommandKind, size: CGFloat) -> some View {
        Button {
            action(kind)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size))
                .contentTransition(.symbolEffect(.replace))
                .frame(maxWidth: .infinity, minHeight: 60)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
