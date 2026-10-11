import SwiftUI

/// A small status capsule shown briefly over the video when the session starts or the screen is tapped.
struct ConnectionControls: View {
    @Environment(AppModel.self) private var model
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Label(model.connectionSummary, systemImage: model.connectionKind?.systemImage ?? "display")
                .font(.subheadline.weight(.medium))
                .lineLimit(1)

            if model.acceptsInput {
                Button(action: model.toggleSoftwareKeyboard) {
                    Image(systemName: "keyboard")
                        .font(.title3)
                }
                .accessibilityLabel("Show or hide the keyboard")
            }

            Menu {
                Button {
                    model.showLastArrowAgain()
                } label: {
                    Label("Show Display Position", systemImage: "rectangle.on.rectangle")
                }
                .disabled(model.lastEdge == nil)

                Button(action: openSettings) {
                    Label("Settings", systemImage: "gearshape")
                }

                Divider()

                Button(role: .destructive) {
                    model.disconnectAndPause()
                } label: {
                    Label("Disconnect", systemImage: "xmark.circle")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
            }
            .accessibilityLabel("Connection options")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 16)
    }
}
