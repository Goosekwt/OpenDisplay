import SwiftUI

/// The temporary blue arrow at the edge facing the PC's display, pointing outward toward it.
/// Edges are physical, so the layer is pinned left-to-right even in right-to-left languages.
struct EdgeArrowLayer: View {
    let request: EdgeArrowRequest?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let request {
                EdgeArrow(edge: request.edge, reduceMotion: reduceMotion)
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: request.edge.alignment)
                    .id(request.id)
                    .transition(reduceMotion
                        ? .opacity
                        : .move(edge: request.edge.transitionEdge).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.35), value: request?.id)
        .environment(\.layoutDirection, .leftToRight)
        .allowsHitTesting(false)
    }
}

struct EdgeArrow: View {
    let edge: ScreenEdge
    let reduceMotion: Bool
    @State private var nudged = false

    var body: some View {
        Image(systemName: edge.symbolName)
            .font(.system(size: 44, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 96, height: 96)
            .background(Color.blue, in: Circle())
            .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
            .offset(x: nudged ? edge.outwardVector.dx * 10 : 0,
                    y: nudged ? edge.outwardVector.dy * 10 : 0)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { nudged = true }
            }
            .accessibilityElement()
            .accessibilityLabel("Your PC's display is \(edge.spokenPosition)")
    }
}
