import SwiftUI

/// What the iPad shows while it isn't displaying the PC: pairing, waiting, or a problem.
struct StatusPanel: View {
    @Environment(AppModel.self) private var model
    let openSettings: () -> Void
    let scan: () -> Void
    let enterKey: () -> Void

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                content
                if let notice = model.notice {
                    Label(notice, systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 480)
                        .padding(.horizontal, 32)
                        .padding(.bottom, 32)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if model.isPaired {
                Button(action: openSettings) {
                    Image(systemName: "gearshape")
                        .font(.title3)
                        .padding(12)
                }
                .accessibilityLabel("Settings")
                .padding(8)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.status {
        case .unpaired:
            ContentUnavailableView {
                Label("Pair with Your PC", systemImage: "qrcode.viewfinder")
            } description: {
                Text("You only need to pair once. Open OpenDisplay on your PC, then scan its QR code or enter the pairing key. After that, OpenDisplay connects by itself and matches this iPad's screen.")
                    .frame(maxWidth: 480)
            } actions: {
                Button("Scan Pairing Code", action: scan)
                    .buttonStyle(.borderedProminent)
                Button("Enter Key Manually", action: enterKey)
            }

        case .paused:
            ContentUnavailableView {
                Label("Paused", systemImage: "pause.circle")
            } description: {
                Text("This iPad isn't accepting connections from \(model.displayPCName).")
            } actions: {
                Button("Resume") { model.resume() }
                    .buttonStyle(.borderedProminent)
            }

        case .starting, .waiting:
            ContentUnavailableView {
                Label("Waiting for \(model.displayPCName)", systemImage: "display.2")
            } description: {
                Text(waitingDescription)
            } actions: {
                ProgressView()
            }

        case .connected:
            ContentUnavailableView {
                Label("Connected to \(model.displayPCName)", systemImage: model.connectionKind?.systemImage ?? "display.2")
            } description: {
                Text("Waiting for the first frame.")
            } actions: {
                ProgressView()
            }

        case .listenerFailed(let message):
            ContentUnavailableView {
                Label("Can't Accept Connections", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { model.retryListening() }
                    .buttonStyle(.borderedProminent)
            }

        case .streaming:
            EmptyView()
        }
    }

    private var waitingDescription: String {
        let base = "Connect the USB cable, or use the same Wi-Fi network as your PC. While OpenDisplay is running on the PC, it connects automatically and sizes the display to fit this iPad."
        if case .listening(advertising: false) = model.listenerStatus {
            return base + " Wi-Fi discovery is off because Local Network access isn't allowed; USB still works."
        }
        return base
    }
}
