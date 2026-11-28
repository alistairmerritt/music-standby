import AppKit
import CompanionCore
import StandByProtocol

/// Continue from iPhone's question about the phone's Apple Music playlist or
/// album that isn't in the library (28 November 2026): the same words and
/// choices as the iPhone's sheet. An alert's window brought to the front, as
/// the menu has closed by the time the phone answers; the phone plays on
/// while it's open. Remember my choice is the alert's own check box, off
/// until ticked.
///
/// Not run modally: `runModal` held the whole app, so the menu bar menu
/// couldn't open while the question waited, however long. The window is
/// shown on its own and its buttons answer directly; Return is Add & Continue
/// (or Try Again), Escape is Cancel, as in a modal alert.
@MainActor enum LibraryDialog {
    /// "“Today” · Playlist", as the iPhone's sheet says it.
    static func named(_ item: HandBackLibraryItem) -> String? {
        let kind = switch item.kind {
        case HandBackLibraryItem.playlist: "Playlist"
        case HandBackLibraryItem.album: "Album"
        default: ""
        }
        guard !item.name.isEmpty else { return nil }
        // No-break spaces: the alert's narrow text once wrapped "· Playlist"
        // onto a line of its own (28 November 2026).
        return kind.isEmpty ? "“\(item.name)”" : "“\(item.name)”\u{00A0}·\u{00A0}\(kind)"
    }

    static let title = "Add to your library?"
    static let message = "To continue this playlist or album on your Mac, Second Chair may need to add it to your Apple Music library. Anything added stays there until you remove it."
    static let failedTitle = "Couldn’t add it to your library"
    static let failedMessage = "Second Chair couldn’t add this playlist or album to your Apple Music library. Try again, or continue with a station based on the current song."

    /// Nil for Cancel (or Escape).
    /// `item`: the playlist or album, named as on the iPhone's sheet (a
    /// phone that doesn't say leaves the words as they are).
    static func ask(addFailed: Bool, item: HandBackLibraryItem?) async -> LibraryDialogAnswer? {
        let alert = NSAlert()
        alert.messageText = addFailed ? failedTitle : title
        let words = addFailed ? failedMessage : message
        alert.informativeText = item.flatMap(named).map { "\($0)\n\n\(words)" } ?? words
        alert.addButton(withTitle: addFailed ? "Try Again" : "Add & Continue")
        alert.addButton(withTitle: "Play Song Station Instead")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        if !addFailed {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Remember my choice"
            alert.suppressionButton?.state = .off
        }
        // Let the menu finish closing, then come to the front over other apps.
        await Task.yield()
        alert.layout()
        let window = alert.window
        window.level = .floating
        let pressed = await withCheckedContinuation { (reply: CheckedContinuation<Int, Never>) in
            let buttons = ButtonReply(reply)
            open = buttons
            for (index, button) in alert.buttons.enumerated() {
                button.tag = index
                button.target = buttons
                button.action = #selector(ButtonReply.pressed(_:))
            }
            window.center()
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
        open = nil
        window.orderOut(nil)
        let remember = !addFailed && alert.suppressionButton?.state == .on
        switch pressed {
        case 0: return LibraryDialogAnswer(choice: .add, remember: remember)
        case 1: return LibraryDialogAnswer(choice: .station, remember: remember)
        default: return nil
        }
    }

    /// Keeps the open dialog's buttons answering (their target is weak).
    private static var open: ButtonReply?
}

/// The dialog's buttons: the first press answers, once.
@MainActor private final class ButtonReply: NSObject {
    private var reply: CheckedContinuation<Int, Never>?
    init(_ reply: CheckedContinuation<Int, Never>) { self.reply = reply }

    @objc func pressed(_ sender: NSButton) {
        reply?.resume(returning: sender.tag)
        reply = nil
    }
}
