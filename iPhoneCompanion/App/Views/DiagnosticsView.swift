import StandByKit
import SwiftUI
import UIKit

struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model
    @State private var record: [LockScreenRecord.Entry] = []

    var body: some View {
        Form {
            // What happened around the Lock Screen player, kept across
            // launches: the reminder, the shortcut's action, the app opening.
            Section {
                if record.isEmpty {
                    Text("Nothing yet. It fills in as reminders arrive and Show in Now Playing runs.").foregroundStyle(.secondary)
                }
                ForEach(record.prefix(60)) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.message).font(.footnote)
                        Text(entry.date.formatted(.dateTime.day().month(.abbreviated).hour().minute().second()))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if !record.isEmpty {
                    Button("Copy Record", systemImage: "doc.on.doc") { UIPasteboard.general.string = LockScreenRecord.text() }
                    Button("Clear Record", systemImage: "trash", role: .destructive) {
                        LockScreenRecord.clear()
                        record = []
                    }
                }
            } header: {
                Text("Lock Screen Record")
            }

            Section("Remote Session") {
                LabeledContent("Active", value: model.sessionController.isActive ? "Yes" : "No")
                LabeledContent("System Primary", value: model.sessionController.isSystemPrimary ? "Yes" : "No")
                LabeledContent("Session ID", value: model.sessionController.sessionID ?? "None")
                LabeledContent("Revision", value: model.attributes.map { String($0.revision) } ?? "None")
                LabeledContent("App Group", value: model.container.isShared ? "Available" : "Missing")
                if let error = model.sessionController.lastError {
                    Text(error).font(.footnote).foregroundStyle(.red).textSelection(.enabled)
                }
                if let error = model.sessionController.lastPrimaryError {
                    Text("Primary refused: \(error)").font(.footnote).foregroundStyle(.orange).textSelection(.enabled)
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
        .refreshable {
            model.refreshDiagnostics()
            record = LockScreenRecord.entries()
        }
        .onAppear {
            model.refreshDiagnostics()
            record = LockScreenRecord.entries()
        }
    }

    /// Shortened on screen; the whole token is a long press away, for support.
    private func token(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
            Text(value.map(Self.shortened) ?? "Not issued").font(.caption.monospaced()).foregroundStyle(.secondary)
        }
        .contextMenu {
            if let value {
                Button("Copy Token", systemImage: "doc.on.doc") { UIPasteboard.general.string = value }
            }
        }
    }

    static func shortened(_ token: String) -> String {
        token.count > 16 ? "\(token.prefix(8))…\(token.suffix(4))" : token
    }
}
