import SwiftUI

/// Fallback when the camera can't be used: type or paste the base64url key (or the whole link).
struct ManualKeyEntryView: View {
    @Environment(AppModel.self) private var model
    let onPaired: () -> Void

    @State private var keyText = ""
    @State private var nameText = ""
    @State private var errorText: String?

    private var enteredLink: Bool { keyText.contains("://") }

    var body: some View {
        Form {
            Section {
                TextField("Pairing key", text: $keyText, axis: .vertical)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .onSubmit(pair)
                PasteButton(payloadType: String.self) { strings in
                    if let first = strings.first { keyText = first }
                }
            } header: {
                Text("Key")
            } footer: {
                if let errorText {
                    Text(errorText).foregroundStyle(.red)
                } else {
                    Text("Enter the 43-character key shown on your PC, or paste the whole pairing link. Letters are case-sensitive.")
                }
            }

            if !enteredLink {
                Section("PC Name (Optional)") {
                    TextField("PC name", text: $nameText)
                        .textInputAutocapitalization(.words)
                        .onSubmit(pair)
                }
            }
        }
        .navigationTitle("Enter Pairing Key")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Pair", action: pair)
                    .disabled(keyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onChange(of: keyText) { errorText = nil }
    }

    private func pair() {
        do {
            var code = try PairingCode.parse(keyText)
            if code.pcName == nil, let name = PairingCode.sanitizedName(nameText) {
                code = PairingCode(key: code.key, pcName: name)
            }
            try model.pair(with: code)
            onPaired()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
