import StandByKit
import SwiftUI

/// Continue on Mac's question about an Apple Music playlist or album that
/// isn't in the library (28 November 2026; StandByKit's `LibraryChoice.swift`).
/// The same words and choices as the Mac's dialog. A sheet rather than an
/// alert, which can't hold Remember my choice. Music here plays on while it's
/// open; closing it without a choice is Cancel.
@MainActor final class LibraryPrompt: Identifiable {
    let id = UUID()
    let question: LibraryQuestion
    private var reply: CheckedContinuation<LibraryAnswer, Never>?

    init(_ question: LibraryQuestion, reply: CheckedContinuation<LibraryAnswer, Never>) {
        self.question = question
        self.reply = reply
    }

    /// Answers once; later calls (the sheet closing after a button) do nothing.
    func answer(_ answer: LibraryAnswer) {
        reply?.resume(returning: answer)
        reply = nil
    }
}

struct LibraryChoiceSheet: View {
    let prompt: LibraryPrompt
    @Environment(\.dismiss) private var dismiss
    @State private var remember = false

    static let title = "Add to your library?"
    static let message = "To continue this playlist or album on your Mac, Second Chair needs to add it to your Apple Music library. It’ll stay there until you remove it."
    static let failedTitle = "Couldn’t add it to your library"
    static let failedMessage = "Second Chair couldn’t add this playlist or album to your Apple Music library. Try again, or continue with a station based on the current song."

    private var failed: Bool { prompt.question.addFailed }

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Text(failed ? Self.failedTitle : Self.title)
                    .font(.title3.weight(.semibold))
                Text("“\(prompt.question.name)” · \(prompt.question.kind == .playlist ? "Playlist" : "Album")")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(failed ? Self.failedMessage : Self.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            if !failed {
                Toggle("Remember my choice", isOn: $remember)
                    .font(.subheadline)
            }

            VStack(spacing: 10) {
                Button {
                    finish(.add(remember: remember && !failed))
                } label: {
                    Text(failed ? "Try Again" : "Add & Continue").frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.borderedProminent)
                Button {
                    finish(.station(remember: remember && !failed))
                } label: {
                    Text("Play Song Station").frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.bordered)
                Button("Cancel", role: .cancel) { finish(.cancel) }
                    .padding(.top, 4)
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 12)
        .presentationDetents([.height(failed ? 360 : 400)])
        .presentationDragIndicator(.visible)
        // Swiped away: Cancel. Here rather than in the sheet's onDismiss, where
        // SwiftUI has already cleared the binding (device test 3, 28 November
        // 2026: the hand-over waited for ever). After a button, it does nothing.
        .onDisappear { prompt.answer(.cancel) }
    }

    private func finish(_ answer: LibraryAnswer) {
        prompt.answer(answer)
        dismiss()
    }
}
