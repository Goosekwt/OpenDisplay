import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var sheet: Sheet?
    @State private var controlsVisible = false
    @State private var controlsToken = UUID()

    enum Sheet: String, Identifiable {
        case settings, scanner, manualKey
        var id: String { rawValue }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Always in the hierarchy, so the display layer is never torn down mid-stream.
            VideoSurface(view: model.surface)
                .ignoresSafeArea()
                .opacity(model.hasVideo ? 1 : 0)
                .accessibilityHidden(!model.hasVideo)

            if model.hasVideo {
                // v1 sends no input to the PC, so a tap only reveals the connection controls.
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture { revealControls() }
                    .accessibilityElement()
                    .accessibilityLabel("Show connection controls")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { revealControls() }
            } else {
                StatusPanel(
                    openSettings: { sheet = .settings },
                    scan: { sheet = .scanner },
                    enterKey: { sheet = .manualKey }
                )
                .transition(.opacity)
            }

            EdgeArrowLayer(request: model.arrow)

            if model.hasVideo && controlsVisible {
                ConnectionControls(openSettings: { sheet = .settings })
                    .transition(.opacity)
            }
        }
        .statusBarHidden(model.hasVideo)
        .persistentSystemOverlays(model.hasVideo ? .hidden : .automatic)
        .animation(.easeInOut(duration: 0.2), value: model.hasVideo)
        .animation(.easeInOut(duration: 0.2), value: controlsVisible)
        .onChange(of: scenePhase, initial: true) { _, phase in
            model.scenePhaseChanged(phase)
        }
        .onChange(of: model.hasVideo) { _, hasVideo in
            if hasVideo { revealControls() } else { controlsVisible = false }
        }
        .task(id: controlsToken) {
            guard controlsVisible else { return }
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { controlsVisible = false }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .settings:
                SettingsView()
            case .scanner:
                NavigationStack {
                    ScannerScreen(onPaired: { self.sheet = nil })
                        .toolbar { cancelButton }
                }
            case .manualKey:
                NavigationStack {
                    ManualKeyEntryView(onPaired: { self.sheet = nil })
                        .toolbar { cancelButton }
                }
            }
        }
    }

    private var cancelButton: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { sheet = nil }
        }
    }

    private func revealControls() {
        controlsVisible = true
        controlsToken = UUID()
    }
}
