import StandByKit
import SwiftUI

struct PairingView: View {
    @Environment(AppModel.self) private var model
    @State private var code = ""
    @State private var isPairing = false
    @State private var errorMessage: String?
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        Form {
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
                Text(errorMessage ?? "Enter the six-digit code shown by Music StandBy on your Mac.")
                    .foregroundStyle(errorMessage == nil ? Color.secondary : Color.red)
            }

            Section {
                Button {
                    Task { await pair() }
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
        .navigationTitle("Pair with Mac")
        .onAppear { isFieldFocused = true }
    }

    private func pair() async {
        isPairing = true
        defer { isPairing = false }
        do {
            try await model.pair(rawCode: code)
        } catch {
            errorMessage = error.localizedDescription
            code = ""
        }
    }
}
