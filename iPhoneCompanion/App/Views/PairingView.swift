import StandByKit
import SwiftUI

struct PairingView: View {
    @Environment(AppModel.self) private var model
    @State private var code = ""
    @State private var pairing: Task<Void, Never>?
    @State private var errorMessage: String?
    @FocusState private var isFieldFocused: Bool

    private var isPairing: Bool { pairing != nil }

    var body: some View {
        Form {
            if let mac = model.pairingAwaitingMac {
                waiting(for: mac)
            } else {
                entry
            }
        }
        .navigationTitle("Pair with Mac")
        .onAppear { isFieldFocused = true }
    }

    private func waiting(for mac: PairedMac) -> some View {
        Section {
            HStack(spacing: 12) {
                ProgressView()
                Text("Waiting for \(mac.name)…")
            }
            Button("Cancel", role: .cancel) {
                pairing?.cancel()
            }
        } footer: {
            Text("On your Mac, open Second Chair in the menu bar and allow this iPhone.")
        }
    }

    @ViewBuilder private var entry: some View {
        Section {
            TextField("000000", text: $code)
                .focused($isFieldFocused)
                .font(.system(.title, design: .monospaced))
                .multilineTextAlignment(.center)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .accessibilityLabel("Six-digit pairing code")
                .onChange(of: code) { _, newValue in
                    let clean = PairingCode.sanitise(newValue)
                    if clean != newValue { code = clean }
                    errorMessage = nil
                }
        } header: {
            Text("Pairing Code")
        } footer: {
            Text(errorMessage ?? "Enter the six-digit code shown by Second Chair on your Mac.")
                .foregroundStyle(errorMessage == nil ? Color.secondary : Color.red)
        }

        Section {
            Button {
                pairing = Task { await pair() }
            } label: {
                HStack {
                    Text("Pair")
                    Spacer()
                    if isPairing { ProgressView() }
                }
            }
            .disabled(PairingCode(code) == nil || isPairing)
        }
    }

    private func pair() async {
        defer { pairing = nil }
        do {
            try await model.pair(rawCode: code)
        } catch is CancellationError {
            errorMessage = "Pairing cancelled."
            code = ""
        } catch {
            errorMessage = error.localizedDescription
            code = ""
        }
    }
}
