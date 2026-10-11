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

            if model.acceptsInput {
                // Touch, trackpad and keyboard go to the PC; the controls live behind a small top-edge button.
                RemoteInputSurface(view: model.remoteInput, isForwarding: isForwardingInput,
                                   videoSize: model.videoContentSize)
                    .ignoresSafeArea()
            } else if model.hasVideo {
                // This host accepts no input, so a tap only reveals the connection controls.
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
            } else if model.acceptsInput {
                ControlsHandle(action: revealControls)
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
        .onChange(of: controlsVisible) { _, visible in
            // A control or its menu may have taken keyboard focus; the stream gets it back when they close.
            if !visible { model.remoteInput.reclaimFocusIfNeeded() }
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

    /// Input reaches the PC only while streaming in the foreground with no sheet over the video.
    private var isForwardingInput: Bool {
        model.acceptsInput && sheet == nil && scenePhase == .active
    }

    private func revealControls() {
        controlsVisible = true
        controlsToken = UUID()
    }
}

/// A small, always-available button at the top edge that reveals the connection controls
/// without taking any of the screen away from remote input.
private struct ControlsHandle: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.compact.down")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 56, height: 22)
                .background(.black.opacity(0.35), in: Capsule())
                .frame(width: 72, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show connection controls")
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
