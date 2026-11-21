import StandByKit
import SwiftUI
import UIKit

// The first run's pictures (V2, 16 November 2026). Each one is decorative to
// VoiceOver beyond its one-line description, and none is a control.

// MARK: - Records and colours

/// The website's invented records, for the welcome picture: covers from the
/// demo, colours from madewithmerritt.com's `coloursFrom()`.
struct DemoRecord: Identifiable {
    let id: String
    let title: String
    let artist: String
    let duration: TimeInterval
    let wall: (top: Color, bottom: Color)

    static let welcome: [DemoRecord] = [
        DemoRecord(id: "low-sun", title: "Low Sun", artist: "Drift Hotel", duration: 214, wall: (Color(hex: 0xBC5B3B), Color(hex: 0x472316))),
        DemoRecord(id: "rooftop-season", title: "Rooftop Season", artist: "Remy Saint", duration: 188, wall: (Color(hex: 0xB59071), Color(hex: 0x6B4F38))),
        DemoRecord(id: "small-hours", title: "Small Hours", artist: "Fen Lights", duration: 252, wall: (Color(hex: 0x8B7756), Color(hex: 0x352D21))),
        DemoRecord(id: "ticket-hall", title: "Ticket Hall", artist: "Polly Atlas", duration: 178, wall: (Color(hex: 0xA27314), Color(hex: 0x3E2C08))),
    ]

    var cover: Image {
        if let data = MockArtwork.cover(id: "mock-art-\(id)"), let image = UIImage(data: data) {
            return Image(uiImage: image)
        }
        return Image(systemName: "music.note")
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// A real song's colours, read the way the website reads a cover: a
/// saturation-weighted average, then darkened enough for white text.
enum ArtworkColours {
    static func wall(for image: CGImage?) -> (top: Color, bottom: Color) {
        guard let image, let (h, s) = hueAndSaturation(image) else { return (Color(white: 0.3), Color(white: 0.1)) }
        let sat = min(0.78, s * 1.08)
        return (Color(hue: h, saturation: sat, brightness: 0.62), Color(hue: h, saturation: sat, brightness: 0.24))
    }

    private static func hueAndSaturation(_ image: CGImage) -> (Double, Double)? {
        let size = 24
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        guard let context = CGContext(data: &pixels, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        var r = 0.0, g = 0.0, b = 0.0, w = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let pr = Double(pixels[i]), pg = Double(pixels[i + 1]), pb = Double(pixels[i + 2])
            let mx = max(pr, pg, pb), mn = min(pr, pg, pb)
            let weight = 0.08 + pow(mx > 0 ? (mx - mn) / mx : 0, 2) * (mx / 255)
            r += pr * weight; g += pg * weight; b += pb * weight; w += weight
        }
        let colour = UIColor(red: r / w / 255, green: g / w / 255, blue: b / w / 255, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        colour.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return (Double(hue), Double(saturation))
    }
}

// MARK: - The player, as a framed picture

/// A Now Playing player on a card tinted by the record: a picture of what the
/// Lock Screen shows, framed so it can't be mistaken for the Lock Screen
/// itself (comparison, correction 3).
struct NowPlayingPicture: View {
    let artwork: Image
    let title: String
    let artist: String
    let source: String
    let wall: (top: Color, bottom: Color)
    var elapsed: TimeInterval = 112
    var duration: TimeInterval = 214
    var artworkNamespace: Namespace.ID?

    var body: some View {
        ZStack {
            LinearGradient(colors: [wall.top, wall.bottom], startPoint: .top, endPoint: .bottom)
            artwork.resizable().scaledToFill().blur(radius: 40).opacity(0.45)
                .id(title)
                .transition(.opacity)
            platter.padding(16)
        }
        .clipShape(.rect(cornerRadius: 30, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.25), radius: 20, y: 10)
        .environment(\.colorScheme, .dark)
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("A picture of the Lock Screen player: \(title) by \(artist), playing from \(source).")
    }

    private var platter: some View {
        VStack(alignment: .leading, spacing: 12) {
            // A change of song: the old song fades out fully before the new
            // one fades in, so the titles never show through each other
            // (a tester saw "Low SunSeason", 21 November 2026).
            ZStack(alignment: .leading) {
                HStack(spacing: 12) {
                    cover.frame(width: 58, height: 58)
                    VStack(alignment: .leading, spacing: 1) {
                        Label(source, systemImage: "laptopcomputer").font(.footnote).foregroundStyle(.white.opacity(0.6)).labelStyle(.titleAndIcon)
                        Text(title).font(.headline).foregroundStyle(.white).lineLimit(1)
                        Text(artist).font(.subheadline).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .id(title)
                .transition(.asymmetric(insertion: .opacity.animation(.easeIn(duration: 0.3).delay(0.3)),
                                        removal: .opacity.animation(.easeOut(duration: 0.25))))
            }
            VStack(spacing: 4) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.25))
                        Capsule().fill(.white.opacity(0.9)).frame(width: proxy.size.width * min(1, elapsed / max(1, duration)))
                    }
                }
                .frame(height: 5)
                HStack {
                    Text(Duration.seconds(elapsed), format: .time(pattern: .minuteSecond))
                    Spacer()
                    Text("−") + Text(Duration.seconds(max(0, duration - elapsed)), format: .time(pattern: .minuteSecond))
                }
                .font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.6))
            }
            HStack(spacing: 44) {
                Image(systemName: "backward.fill")
                Image(systemName: "pause.fill").font(.title)
                Image(systemName: "forward.fill")
            }
            .font(.title2).foregroundStyle(.white).frame(maxWidth: .infinity)
        }
        .padding(16)
        .background(.white.opacity(0.13), in: .rect(cornerRadius: 24, style: .continuous))
    }

    @ViewBuilder private var cover: some View {
        let image = artwork.resizable().scaledToFill().clipShape(.rect(cornerRadius: 10, style: .continuous))
        if let artworkNamespace {
            image.matchedGeometryEffect(id: "artwork", in: artworkNamespace)
        } else {
            image
        }
    }
}

// MARK: - The Mac, drawn

/// A window onto the Mac: its menu bar, with Second Chair's ♪, and one part
/// of Second Chair's menu with the thing to click marked. Built from the Mac
/// menu's own words (`MacMenuText`), so the two can't drift apart
/// (comparison, correction 2). The menu's look follows macOS's: push buttons,
/// the default one blue.
struct MacPicture: View {
    enum Part: Equatable {
        /// Nothing open yet: look for ♪.
        case menuBar
        case pairButton
        case pairingCode
        case allow
        /// The song row and its play button; `artwork` once the Mac has sent it.
        case play(title: String?, artist: String?, playing: Bool)
        case connectToMusic
        case musicCode
        case connectedToMusic
    }

    let part: Part
    var artwork: Image?
    var artworkNamespace: Namespace.ID?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack(alignment: .topTrailing) {
            LinearGradient(colors: scheme == .dark ? [Color(hex: 0x4B5D8F), Color(hex: 0x141526)] : [Color(hex: 0xC9D6F2), Color(hex: 0x7E86B8)],
                           startPoint: .topTrailing, endPoint: .bottomLeading)
            VStack(alignment: .trailing, spacing: 6) {
                menuBar
                if part != .menuBar {
                    HStack(alignment: .top, spacing: 10) {
                        if part == .musicCode { musicWindow }
                        panel
                    }
                    .padding(.trailing, 10)
                }
            }
        }
        .frame(height: part == .menuBar ? 150 : nil)
        .frame(minHeight: 150)
        .clipShape(.rect(cornerRadius: 22, style: .continuous))
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(description)
    }

    private var description: String {
        switch part {
        case .menuBar: "Your Mac’s menu bar, with Second Chair’s music note."
        case .pairButton: "Second Chair’s menu on your Mac, with the \(MacMenuText.pairIPhone) button."
        case .pairingCode: "Second Chair’s menu showing a six-digit code."
        case .allow: "Second Chair’s menu asking to allow this iPhone, with the \(MacMenuText.allow) button."
        case .play: "Second Chair’s menu on your Mac, with the play button."
        case .connectToMusic: "Second Chair’s menu with the \(MacMenuText.connectToMusic) button."
        case .musicCode: "Second Chair’s menu showing a four-digit code, beside Music’s Devices list."
        case .connectedToMusic: "Second Chair’s menu saying it’s connected to Music."
        }
    }

    private var menuBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "music.note")
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(part == .menuBar ? .clear : .white.opacity(0.28), in: .rect(cornerRadius: 5))
                .overlay { if part == .menuBar { RoundedRectangle(cornerRadius: 5).strokeBorder(.yellow, lineWidth: 2).padding(-2) } }
            Image(systemName: "wifi")
            Image(systemName: "battery.75percent")
            Image(systemName: "switch.2")
            Text("Mon 16 Nov  9:41")
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(scheme == .dark ? .white : .black)
        .padding(.horizontal, 12)
        .frame(height: 26)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .background(.ultraThinMaterial)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch part {
            case .menuBar:
                EmptyView()
            // As Mac 0.3.9's menu draws them (21 November 2026): setup as one
            // card at a time, and a status footer with the gear.
            case .pairButton:
                card {
                    Text("Pair your iPhone.").font(.callout.weight(.semibold))
                    Text("Open Second Chair on your iPhone, then pair it with this Mac.").font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    macButton(MacMenuText.pairIPhone, prominent: true, pointed: true)
                }
                footer(paired: false)
            case .pairingCode:
                card {
                    Label("iPhone pairing code", systemImage: "iphone").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Text("• • •  • • •").font(.system(.title2, design: .monospaced).weight(.semibold)).foregroundStyle(.secondary)
                    Text(MacMenuText.typeThisOnIPhone).font(.caption).foregroundStyle(.secondary)
                }
                footer(paired: false)
            case .allow:
                card {
                    Text(MacMenuText.wantsToShow("iPhone")).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        macButton(MacMenuText.dontAllow, prominent: false, pointed: false)
                        macButton(MacMenuText.allow, prominent: true, pointed: true)
                    }
                }
                footer(paired: false)
            case .play(let title, let artist, let playing):
                Text(MacMenuText.onThisMac.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    songArtwork.frame(width: 50, height: 50)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title ?? "Nothing playing").font(.callout.weight(.semibold)).lineLimit(1)
                        if let title, !title.isEmpty {
                            Text(artist ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Text(playing ? "Playing" : "Paused").font(.caption2).foregroundStyle(.tertiary)
                        } else {
                            Text("Play something in Music").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Capsule().fill(.secondary.opacity(0.25)).frame(height: 4)
                    .overlay(alignment: .leading) { Capsule().fill(Color.accentColor).frame(width: title == nil ? 0 : 120, height: 4) }
                HStack(spacing: 26) {
                    Image(systemName: "backward.fill")
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .padding(5).background(playing ? .clear : Color.accentColor.opacity(0.25), in: .circle)
                        .overlay(alignment: .bottomTrailing) { if !playing { pointer.offset(x: 12, y: 14) } }
                    Image(systemName: "forward.fill")
                }
                .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                footer(paired: true)
            case .connectToMusic:
                card {
                    Text("Continue Listening isn’t set up.").font(.callout.weight(.semibold))
                    HStack {
                        macButton(MacMenuText.connectToMusic, prominent: false, pointed: true)
                        Spacer(minLength: 0)
                        Text("Not Now").font(.caption).foregroundStyle(Color.accentColor).lineLimit(1).fixedSize()
                    }
                }
                footer(paired: true)
            case .musicCode:
                card {
                    Label("Music connection code", systemImage: "music.note.house").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Text(MacMenuText.musicCodeNote).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Text("• • • •").font(.system(.title2, design: .monospaced).weight(.semibold)).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        macButton(MacMenuText.cancel, prominent: false, pointed: false)
                    }
                }
            case .connectedToMusic:
                Label(MacMenuText.connectedToMusicNote, systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                footer(paired: true)
            }
        }
        .padding(12)
        .frame(width: part == .musicCode ? 190 : 250, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 6)
        .padding(.bottom, 14)
    }

    /// One setup card, as in the Mac's menu.
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) { content() }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.secondary.opacity(0.12), in: .rect(cornerRadius: 10))
    }

    /// "● Online · iPhone paired" and the gear, the menu's last line.
    private func footer(paired: Bool) -> some View {
        HStack(spacing: 5) {
            Circle().fill(.green).frame(width: 6, height: 6)
            Text(paired ? "Online · iPhone paired" : "Online · No iPhone paired").font(.caption2).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Image(systemName: "gearshape").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.top, 2)
    }

    /// Music's window, with Second Chair selected under Devices, where the four digits go.
    private var musicWindow: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) { ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0).frame(width: 8) } }
                    .padding(.bottom, 8)
                Text("Devices").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Label("Second Chair", systemImage: "laptopcomputer").font(.caption2).lineLimit(1)
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .background(Color.accentColor, in: .rect(cornerRadius: 4)).foregroundStyle(.white)
                    .overlay(alignment: .bottomTrailing) { pointer.offset(x: 10, y: 14) }
            }
            .padding(8)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(.secondary.opacity(0.12))
            HStack(spacing: 3) { ForEach(0..<4, id: \.self) { _ in RoundedRectangle(cornerRadius: 3).fill(.secondary.opacity(0.2)).frame(width: 14, height: 18) } }
                .padding(8).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 150, height: 120)
        .background(.regularMaterial, in: .rect(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 6)
        .padding(.top, 2)
    }

    @ViewBuilder private var songArtwork: some View {
        if let artwork {
            let image = artwork.resizable().scaledToFill().clipShape(.rect(cornerRadius: 6))
            if let artworkNamespace { image.matchedGeometryEffect(id: "artwork", in: artworkNamespace) } else { image }
        } else {
            RoundedRectangle(cornerRadius: 6).fill(.secondary.opacity(0.2)).overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
        }
    }

    private func macButton(_ title: String, prominent: Bool, pointed: Bool) -> some View {
        Text(title)
            .font(.callout)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 12).padding(.vertical, 4)
            .foregroundStyle(prominent ? .white : .primary)
            .background(prominent ? Color.accentColor : Color.primary.opacity(0.1), in: .rect(cornerRadius: 6))
            .overlay(alignment: .bottomTrailing) { if pointed { pointer.offset(x: 10, y: 14) } }
    }

    private var pointer: some View {
        Image(systemName: "cursorarrow").font(.system(size: 18, weight: .regular))
            .foregroundStyle(.black).shadow(color: .white, radius: 0.5).shadow(color: .white, radius: 0.5)
    }
}

// MARK: - Seats: the song moving between devices

/// The website's seats: the device names large, and the song's artwork
/// sitting on the one playing it, with its time and Up Next.
struct SeatsPicture: View {
    let artwork: Image
    let wall: (top: Color, bottom: Color)
    var onPhone: Bool
    var elapsed: TimeInterval = 112

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [wall.top, wall.bottom], startPoint: .top, endPoint: .bottom)
                VStack(alignment: onPhone ? .trailing : .leading, spacing: 8) {
                    artwork.resizable().scaledToFill().frame(width: 96, height: 96)
                        .clipShape(.rect(cornerRadius: 12, style: .continuous))
                        .shadow(color: .black.opacity(0.35), radius: 12, y: 8)
                    // Up Next goes too. The app has no artwork for queued songs, so neutral tiles.
                    HStack(spacing: 4) {
                        ForEach(0..<3, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.35)).frame(width: 20, height: 20)
                        }
                    }
                    Text(Duration.seconds(elapsed), format: .time(pattern: .minuteSecond))
                        .font(.footnote.monospacedDigit().weight(.semibold)).foregroundStyle(.white.opacity(0.85))
                }
                .padding(.top, 22)
                .frame(width: width - 44, alignment: onPhone ? .trailing : .leading)
                .padding(.horizontal, 22)
                HStack {
                    Label("Mac", systemImage: "laptopcomputer").opacity(onPhone ? 0.38 : 1)
                    Spacer()
                    Label("iPhone", systemImage: "iphone").opacity(onPhone ? 1 : 0.38)
                }
                .font(.title2.weight(.bold)).foregroundStyle(.white)
                .padding(.horizontal, 22)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 18)
            }
        }
        .frame(height: 220)
        .clipShape(.rect(cornerRadius: 22, style: .continuous))
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("The song moving from your Mac to your iPhone, at the same point, with what’s up next.")
    }
}
