import AppKit
import CompanionCore

/// Continue from iPhone's question about the phone's Apple Music playlist or
/// album that isn't in the library (28 November 2026): the same words and
/// choices as the iPhone's sheet. An app-modal alert brought to the front, as
/// the menu has closed by the time the phone answers; the phone plays on
/// while it's open. Remember my choice is the alert's own check box, off
/// until ticked.
@MainActor enum LibraryDialog {
    static let title = "Add to your library?"
    static let message = "To continue this playlist or album on your Mac, Second Chair needs to add it to your Apple Music library. It’ll stay there until you remove it."
    static let failedTitle = "Couldn’t add it to your library"
    static let failedMessage = "Second Chair couldn’t add this playlist or album to your Apple Music library. Try again, or continue with a station based on the current song."

    /// Nil for Cancel (or Escape).
    static func ask(addFailed: Bool) async -> LibraryDialogAnswer? {
        let alert = NSAlert()
        alert.messageText = addFailed ? failedTitle : title
        alert.informativeText = addFailed ? failedMessage : message
        alert.addButton(withTitle: addFailed ? "Try Again" : "Add & Continue")
        alert.addButton(withTitle: "Play Song Station")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        if !addFailed {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Remember my choice"
            alert.suppressionButton?.state = .off
        }
        // Let the menu finish closing, then come to the front over other apps.
        await Task.yield()
        NSApp.activate()
        alert.window.level = .floating
        let response = alert.runModal()
        let remember = !addFailed && alert.suppressionButton?.state == .on
        switch response {
        case .alertFirstButtonReturn: return LibraryDialogAnswer(choice: .add, remember: remember)
        case .alertSecondButtonReturn: return LibraryDialogAnswer(choice: .station, remember: remember)
        default: return nil
        }
    }
}
