import StandByKit
import SwiftUI

struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Remote Session") {
                LabeledContent("Active", value: model.sessionController.isActive ? "Yes" : "No")
                LabeledContent("System Primary", value: model.sessionController.isSystemPrimary ? "Yes" : "No")
                LabeledContent("Session ID", value: model.sessionController.sessionID ?? "None")
                LabeledContent("Revision", value: model.attributes.map { String($0.revision) } ?? "None")
                LabeledContent("App Group", value: model.container.isShared ? "Available" : "Missing")
                if let error = model.sessionController.lastError {
                    Text(error).font(.footnote).foregroundStyle(.red).textSelection(.enabled)
                }
            }

            Section("Push Tokens") {
                token("Push to Start", model.pushTokens.pushToStart)
                ForEach(model.pushTokens.sessions.sorted(by: { $0.key < $1.key }), id: \.key) { session, value in
                    token(session, value)
                }
            }

            Section("Commands from System") {
                if model.commandsFromSystem.isEmpty {
                    Text("None yet. Tap a control on the Lock Screen.").foregroundStyle(.secondary)
                }
                ForEach(model.commandsFromSystem.reversed()) { record in
                    LabeledContent(record.kind.rawValue.capitalized, value: record.receivedAt.formatted(date: .omitted, time: .standard))
                }
            }

            Section("Log") {
                ForEach(model.log) { entry in
                    VStack(alignment: .leading) {
                        Text(entry.message).font(.footnote)
                        Text(entry.date.formatted(date: .omitted, time: .standard)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Diagnostics")
        .refreshable { model.refreshDiagnostics() }
        .onAppear { model.refreshDiagnostics() }
    }

    private func token(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
            Text(value ?? "Not issued").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}
