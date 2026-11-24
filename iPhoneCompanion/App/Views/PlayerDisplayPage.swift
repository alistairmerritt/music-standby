import StandByKit
import SwiftUI

/// Settings › Player Display (24 November 2026): Automatic, Now Playing or
/// Live Activity, one at a time, with a checkmark, as in iOS's own Settings.
struct PlayerDisplayPage: View {
    @AppStorage(PlayerDisplay.key, store: LiveActivityController.defaults) private var displayRaw = ""
    @State private var problem: String?
    @State private var switching = false

    private var display: PlayerDisplay { PlayerDisplay(rawValue: displayRaw) ?? LiveActivityController.display }

    var body: some View {
        Form {
            Section {
                ForEach(PlayerDisplay.allCases) { option in
                    Button {
                        choose(option)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(option.title + (option == .automatic ? " (Recommended)" : ""))
                                    .foregroundStyle(.primary)
                                Text(option.summary)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "checkmark")
                                .fontWeight(.semibold)
                                .foregroundStyle(.tint)
                                .opacity(option == display ? 1 : 0)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(switching)
                    .accessibilityAddTraits(option == display ? .isSelected : [])
                }
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    if display.usesLiveActivity && !LiveActivityController.systemAllows {
                        Text("Live Activities are turned off for Second Chair in Settings.").foregroundStyle(.red)
                    }
                    if let problem {
                        Text(problem).foregroundStyle(.red)
                    }
                }
            }
        }
        .navigationTitle("Player Display")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func choose(_ option: PlayerDisplay) {
        guard option != display else { return }
        problem = nil
        switching = true
        Task {
            problem = await LiveActivityController.shared.setDisplay(option)
            switching = false
        }
    }
}
