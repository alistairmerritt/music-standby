import SwiftUI

struct IntroView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            Image(systemName: "laptopcomputer.and.iphone")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Music from Your Mac")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 20) {
                row("music.note", "See what’s playing", "Artwork, song and progress from Apple Music on your Mac.")
                row("playpause.fill", "Control it from here", "Play, pause and skip. The music keeps playing on your Mac.")
                row("iphone.gen3.radiowaves.left.and.right", "Set it down to charge", "Your iPhone can show it in StandBy.")
            }
            Spacer()
            Button {
                model.finishIntro()
            } label: {
                Text("Continue").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(24)
    }

    private func row(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}
