import AppKit
import CompanionCore
import StandByProtocol
import SwiftUI

/// For review only: `MSB_RENDER_MENU_STATES=<folder>` draws the panel in each
/// state, light and dark, to PNGs and quits (21 November 2026). A
/// MenuBarExtra window can't be screenshotted reliably by script, and
/// `ImageRenderer` can't draw AppKit-backed buttons, so each state is hosted
/// in an offscreen window and cached from there. Nothing here runs normally.
@MainActor
enum MenuRender {
    static var folder: URL? {
        ProcessInfo.processInfo.environment["MSB_RENDER_MENU_STATES"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func run(into folder: URL) -> Never {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, model) in fixtures {
            for dark in [false, true] {
                let view = MenuLayout(model: model, actions: MenuActions()) { EmptyView() }
                    .background(Color(nsColor: .windowBackgroundColor))
                let host = NSHostingView(rootView: view)
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let size = host.fittingSize
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = host.appearance
                window.contentView = host
                host.frame = NSRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.15))
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                host.cacheDisplay(in: host.bounds, to: rep)
                let file = folder.appendingPathComponent("\(name)\(dark ? "-dark" : "").png")
                try? rep.representation(using: .png, properties: [:])?.write(to: file)
            }
        }
        exit(0)
    }

    private static var artwork: Data? {
        let size = NSSize(width: 152, height: 152)
        let image = NSImage(size: size)
        image.lockFocus()
        NSGradient(colors: [NSColor(red: 0.85, green: 0.42, blue: 0.25, alpha: 1), NSColor(red: 0.25, green: 0.12, blue: 0.2, alpha: 1)])?
            .draw(in: NSRect(origin: .zero, size: size), angle: -70)
        NSColor(red: 1, green: 0.55, blue: 0.3, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 46, y: 40, width: 60, height: 60)).fill()
        image.unlockFocus()
        return image.tiffRepresentation
    }

    private static func track(_ state: PlaybackState) -> MenuModel.Music {
        .track(.init(title: "Burn the Heather", artist: "The Lounge Society", album: "Silk for the Starving",
                     artwork: artwork, state: state, duration: 209, elapsed: { _ in 48 }))
    }

    private static func base(_ music: MenuModel.Music) -> MenuModel {
        MenuModel(music: music, phase: .connected, phonePaired: true, launchAtLogin: true, musicLink: .connected,
                  version: "Second Chair 0.3.9 (12)")
    }

    private static var fixtures: [(String, MenuModel)] {
        var paused = base(track(.paused)); paused.offersContinueFromPhone = true
        var handed = base(track(.paused)); handed.offersContinueFromPhone = true; handed.handedOver = true
        var asking = handed; asking.handBack = HandBackProgress(id: UUID(), status: .asked)
        var notified = handed; notified.handBack = HandBackProgress(id: UUID(), status: .notified)
        var failed = handed; failed.handBack = HandBackProgress(id: UUID(), timedOut: true)
        var notInQueue = paused; notInQueue.handBack = HandBackProgress(id: UUID(), status: .notInQueue)
        var offline = base(track(.playing)); offline.phase = .failed; offline.failureCode = "not_connected"
        var reconnecting = base(track(.playing)); reconnecting.phase = .reconnecting
        var unpaired = base(track(.playing)); unpaired.phonePaired = false; unpaired.setup = .pairStart(enabled: true)
        var code = base(track(.playing)); code.phonePaired = false
        code.setup = .pairCode(code: "482916", expiresAt: Date().addingTimeInterval(277))
        var allow = base(track(.playing)); allow.phonePaired = false; allow.setup = .pairRequest(phoneName: "iPhone")
        var unpair = base(track(.playing)); unpair.setup = .confirmUnpair
        var clRow = base(track(.playing)); clRow.musicLink = .notConnected; clRow.setup = .continueListeningNotSetUp
        var musicCode = base(track(.playing)); musicCode.musicLink = .connecting; musicCode.setup = .musicCode("3715")
        var forgotten = base(track(.playing)); forgotten.musicLink = .forgotten; forgotten.setup = .musicForgotten
        var justConnected = base(track(.playing)); justConnected.setup = .musicJustConnected
        var launchTip = base(track(.playing)); launchTip.launchAtLogin = false; launchTip.setup = .launchTip
        var nothing = base(.nothing); nothing.offersContinueFromPhone = true
        var choosing = handed
        choosing.handBack = HandBackProgress(id: UUID(), status: .needsLibraryChoice, item: HandBackLibraryItem(kind: "playlist", name: "Today"), askingYou: true)
        var adding = handed; adding.handBack = HandBackProgress(id: UUID(), status: .working, library: .add)
        var cancelled = handed; cancelled.handBack = HandBackProgress(id: UUID(), status: .cancelled)
        var addFailed = handed; addFailed.handBack = HandBackProgress(id: UUID(), status: .libraryAddFailed)
        return [
            ("01-playing", base(track(.playing))),
            ("02-paused", paused),
            ("03-continued-on-iphone", handed),
            ("04-hand-back-asking", asking),
            ("05-hand-back-notification", notified),
            ("06-hand-back-failed", failed),
            ("07-hand-back-not-in-queue", notInQueue),
            ("07a-hand-back-choosing", choosing),
            ("07b-hand-back-adding", adding),
            ("07c-hand-back-cancelled", cancelled),
            ("07d-hand-back-add-failed", addFailed),
            ("08-nothing-playing", nothing),
            ("09-music-not-running", base(.notRunning)),
            ("10-automation-denied", base(.automationDenied)),
            ("11-music-slow", base(.slow)),
            ("12-server-offline", offline),
            ("13-reconnecting", reconnecting),
            ("14-no-iphone", unpaired),
            ("15-pairing-code", code),
            ("16-allow", allow),
            ("17-unpair-confirm", unpair),
            ("18-continue-listening-not-set-up", clRow),
            ("19-music-code", musicCode),
            ("20-music-forgotten", forgotten),
            ("21-music-just-connected", justConnected),
            ("22-launch-tip", launchTip),
        ]
    }
}
