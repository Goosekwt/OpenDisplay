import AVFoundation
import CoreGraphics

/// Where the aspect-fit video sits inside the view, and view points to normalized PC coordinates.
struct VideoContentGeometry: Equatable {
    /// The video's rectangle in view points, excluding any letterbox bars.
    let contentRect: CGRect

    /// Matches `AVLayerVideoGravity.resizeAspect`. Nil until both sizes are real.
    init?(videoSize: CGSize, bounds: CGRect) {
        guard videoSize.width > 0, videoSize.height > 0, bounds.width > 0, bounds.height > 0,
              videoSize.width.isFinite, videoSize.height.isFinite
        else { return nil }
        contentRect = AVMakeRect(aspectRatio: videoSize, insideRect: bounds)
    }

    /// Normalized position, or nil when the point is outside the picture (a touch on a letterbox bar).
    func normalizedInside(_ point: CGPoint) -> CGPoint? {
        let tolerance: CGFloat = 0.5
        guard point.x >= contentRect.minX - tolerance, point.x <= contentRect.maxX + tolerance,
              point.y >= contentRect.minY - tolerance, point.y <= contentRect.maxY + tolerance
        else { return nil }
        return normalizedClamped(point)
    }

    /// Normalized position clamped to the picture's edges, for a drag that has wandered outside it.
    func normalizedClamped(_ point: CGPoint) -> CGPoint {
        let x = (point.x - contentRect.minX) / contentRect.width
        let y = (point.y - contentRect.minY) / contentRect.height
        return CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }
}
