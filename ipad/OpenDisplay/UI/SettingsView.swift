import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmForget = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Paired PC") {
                    if model.isPaired {
                        LabeledContent("Name", value: model.pairedPCName ?? "Unnamed PC")
                        LabeledContent("Status", value: model.statusText)
                    } else {
                        Text("No PC is paired.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    NavigationLink {
                        ScannerScreen(onPaired: { dismiss() })
                    } label: {
                        Label(model.isPaired ? "Pair Again with Code" : "Scan Pairing Code", systemImage: "qrcode.viewfinder")
                    }
                    NavigationLink {
                        ManualKeyEntryView(onPaired: { dismiss() })
                    } label: {
                        Label("Enter Key Manually", systemImage: "keyboard")
                    }
                } footer: {
                    Text("Pairing again replaces the saved key. The pairing key stays in this iPad's Keychain and isn't synced.")
                }

                if model.isPaired {
                    Section {
                        Button("Forget This PC", role: .destructive) { confirmForget = true }
                    }
                }

                Section {
                    LabeledContent("Display Size", value: model.displaySize.map { "\($0) (automatic)" } ?? "Automatic")
                    LabeledContent("Port", value: String(DisplayServer.defaultPort))
                    LabeledContent("Wi-Fi Discovery", value: model.isAdvertisingOnWiFi ? "On" : "Off")
                } header: {
                    Text("Connection")
                } footer: {
                    Text("The PC matches its display to this iPad's screen and reconnects after you rotate the iPad. This version shows your PC's screen over USB or Wi-Fi. It doesn't include audio, touch, keyboard or Apple Pencil input.")
                }
            }
            .navigationTitle("OpenDisplay")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Forget this PC?", isPresented: $confirmForget, titleVisibility: .visible) {
                Button("Forget PC", role: .destructive) { model.forgetPairing() }
            } message: {
                Text("You'll need to pair again before this iPad can show the PC's screen.")
            }
        }
    }
}
