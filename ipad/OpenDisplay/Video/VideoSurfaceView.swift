import AVFoundation
import SwiftUI
import UIKit

/// A view backed by AVSampleBufferDisplayLayer, so decoded frames go straight to the compositor.
final class VideoSurfaceView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    /// Called on the main thread whenever the viewport's pixel size changes (rotation, Split View, Stage Manager).
    var onPixelSizeChange: ((PixelSize) -> Void)?
    private var reportedSize: PixelSize?

    override func layoutSubviews() {
        super.layoutSubviews()
        reportPixelSize()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        reportPixelSize()
    }

    private func reportPixelSize() {
        guard let window else { return }
        let scale = window.windowScene?.screen.nativeScale ?? traitCollection.displayScale
        guard let size = PixelSize(points: bounds.size, scale: scale), size != reportedSize else { return }
        reportedSize = size
        onPixelSizeChange?(size)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
        isAccessibilityElement = true
        accessibilityLabel = "PC display"
        accessibilityTraits = .image
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// Hosts the app's single, long-lived surface view.
struct VideoSurface: UIViewRepresentable {
    let view: VideoSurfaceView

    func makeUIView(context: Context) -> VideoSurfaceView { view }
    func updateUIView(_ uiView: VideoSurfaceView, context: Context) {}
}
