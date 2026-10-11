import AVFoundation
import SwiftUI
import UIKit
import XCTest
@testable import OpenDisplay

/// The picture fills the screen edge to edge, video and input agree on where it is, and the size sent to
/// the PC is the full canvas no matter what safe areas, controls or the keyboard do.
@MainActor
final class StreamLayoutTests: XCTestCase {
    private var window: UIWindow!

    override func tearDown() async throws {
        window?.isHidden = true
        window = nil
    }

    private func spin(_ seconds: TimeInterval = 0.1) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func assertRect(_ a: CGRect, _ b: CGRect, accuracy: CGFloat = 0.01, _ message: String = "",
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.minX, b.minX, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(a.minY, b.minY, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(a.width, b.width, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(a.height, b.height, accuracy: accuracy, message, file: file, line: line)
    }

    private func makeStreamingRoot(size: CGSize, video: CGSize) throws -> (AppModel, UIHostingController<AnyView>) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            throw XCTSkip("No window scene in the test host.")
        }
        let model = AppModel()
        // A bare hosting controller isn't part of the app's SwiftUI scene, so give it the active phase directly.
        let host = UIHostingController(rootView: AnyView(RootView().environment(model).environment(\.scenePhase, .active)))
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = host
        window.makeKeyAndVisible()

        model.handle(.sessionStarted)
        model.handle(.hello(WindowsHello(name: "PC", width: Int(video.width), height: Int(video.height),
                                         fps: 60, transport: "USB", inputVersion: InputEvent.protocolVersion)))
        model.handle(.videoSize(video))
        model.handle(.firstFrame)
        spin(0.3)
        window.layoutIfNeeded()
        XCTAssertTrue(model.acceptsInput)
        XCTAssertTrue(model.remoteInput.isForwarding)
        XCTAssertTrue(model.remoteInput.isFirstResponder, "the stream has keyboard focus")
        return (model, host)
    }

    private struct Snapshot: Equatable {
        var surface: CGRect
        var input: CGRect
        var inputPicture: CGRect?
    }

    private func snapshot(_ model: AppModel) -> Snapshot {
        Snapshot(surface: model.surface.convert(model.surface.bounds, to: window),
                 input: model.remoteInput.convert(model.remoteInput.bounds, to: window),
                 inputPicture: model.remoteInput.controller.geometry.map {
                     model.remoteInput.convert($0.contentRect, to: window)
                 })
    }

    private func checkStreamingLayout(size: CGSize, video: CGSize) throws {
        let (model, host) = try makeStreamingRoot(size: size, video: video)
        defer { model.handle(.sessionEnded(.stopped)) }
        let scale = window.windowScene?.screen.nativeScale ?? window.traitCollection.displayScale

        var reports: [PixelSize] = []
        let original = model.surface.onPixelSizeChange
        model.surface.onPixelSizeChange = { reports.append($0); original?($0) }

        let initial = snapshot(model)
        assertRect(initial.surface, window.bounds, "video fills the window edge to edge")
        assertRect(initial.input, window.bounds, "input fills the window edge to edge")
        XCTAssertEqual(model.surface.displayLayer.videoGravity, .resizeAspect, "never stretched or cropped")
        // Same aspect as the screen, so the picture is the whole window: no bars, no padding.
        assertRect(try XCTUnwrap(initial.inputPicture), window.bounds, "touches map to the whole screen")
        assertRect(AVMakeRect(aspectRatio: video, insideRect: initial.surface), window.bounds)
        XCTAssertEqual(model.displaySize, PixelSize(points: window.bounds.size, scale: scale), "PC gets the full canvas")
        XCTAssertEqual(model.displaySize, PixelSize(width: Int(video.width), height: Int(video.height)))

        // Pointer: hidden anywhere over the picture, which here reaches every edge.
        let input = model.remoteInput
        XCTAssertTrue(input.hidesPointer(at: CGPoint(x: window.bounds.midX, y: window.bounds.midY)))
        XCTAssertTrue(input.hidesPointer(at: CGPoint(x: 1, y: 1)))
        XCTAssertTrue(input.hidesPointer(at: CGPoint(x: window.bounds.maxX - 1, y: window.bounds.maxY - 1)))

        // Safe areas (status bar, home indicator, Stage Manager chrome) change nothing.
        host.additionalSafeAreaInsets = UIEdgeInsets(top: 24, left: 20, bottom: 20, right: 20)
        spin()
        window.layoutIfNeeded()
        XCTAssertEqual(snapshot(model), initial, "safe areas don't move the picture")

        // The on-screen keyboard, real if the simulator shows one, plus a keyboard frame change for certain.
        input.toggleSoftwareKeyboard()
        spin(0.8)
        let keyboard = CGRect(x: 0, y: window.bounds.maxY - 400, width: window.bounds.width, height: 400)
        for name in [UIResponder.keyboardWillShowNotification, UIResponder.keyboardWillChangeFrameNotification,
                     UIResponder.keyboardDidShowNotification] {
            NotificationCenter.default.post(name: name, object: nil, userInfo: [
                UIResponder.keyboardFrameBeginUserInfoKey: NSValue(cgRect: keyboard.offsetBy(dx: 0, dy: 400)),
                UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: keyboard),
                UIResponder.keyboardAnimationDurationUserInfoKey: 0.0,
                UIResponder.keyboardAnimationCurveUserInfoKey: UIView.AnimationCurve.easeInOut.rawValue,
                UIResponder.keyboardIsLocalUserInfoKey: true,
            ])
        }
        spin(0.7)  // longer than the resize settle time
        window.layoutIfNeeded()
        XCTAssertEqual(snapshot(model), initial, "the keyboard doesn't move or shrink the picture")
        input.toggleSoftwareKeyboard()
        spin(0.3)
        XCTAssertTrue(input.isFirstResponder, "focus returns to the stream after the keyboard")

        // Controls visible over the stream change nothing either.
        XCTAssertEqual(snapshot(model), initial)
        XCTAssertEqual(reports, [], "no new viewport, so no reconnect")
        XCTAssertEqual(model.displaySize, PixelSize(points: window.bounds.size, scale: scale))
    }

    func testLandscapeStreamingLayout() throws {
        try checkStreamingLayout(size: CGSize(width: 1210, height: 834), video: CGSize(width: 2420, height: 1668))
    }

    func testPortraitStreamingLayout() throws {
        try checkStreamingLayout(size: CGSize(width: 834, height: 1210), video: CGSize(width: 1668, height: 2420))
    }

    /// A picture of another shape (before the PC follows a resize) gets letterbox bars from aspect fit;
    /// the pointer shows over the bars and hides over the picture, and touches map through the same rectangle.
    func testMismatchedPictureMapsAndShowsPointerOverBars() throws {
        let (model, _) = try makeStreamingRoot(size: CGSize(width: 1210, height: 834), video: CGSize(width: 1600, height: 1000))
        defer { model.handle(.sessionEnded(.stopped)) }
        let picture = try XCTUnwrap(model.remoteInput.controller.geometry?.contentRect)
        let shown = AVMakeRect(aspectRatio: CGSize(width: 1600, height: 1000), insideRect: model.surface.bounds)
        assertRect(picture, shown)
        assertRect(picture, CGRect(x: 0, y: (834 - 1210 / 1.6) / 2, width: 1210, height: 1210 / 1.6))
        XCTAssertFalse(model.remoteInput.hidesPointer(at: CGPoint(x: 605, y: 5)), "top bar")
        XCTAssertFalse(model.remoteInput.hidesPointer(at: CGPoint(x: 605, y: 829)), "bottom bar")
        XCTAssertTrue(model.remoteInput.hidesPointer(at: CGPoint(x: 605, y: 417)))
        XCTAssertTrue(model.remoteInput.hidesPointer(at: CGPoint(x: 1, y: picture.minY + 1)))
    }

    /// A true window size change (rotation, Stage Manager) still renegotiates, with the full new canvas.
    func testRealResizeStillRenegotiatesFullCanvas() throws {
        let (model, _) = try makeStreamingRoot(size: CGSize(width: 1210, height: 834), video: CGSize(width: 2420, height: 1668))
        defer { model.handle(.sessionEnded(.stopped)) }
        let scale = window.windowScene?.screen.nativeScale ?? window.traitCollection.displayScale
        var reports: [PixelSize] = []
        let original = model.surface.onPixelSizeChange
        model.surface.onPixelSizeChange = { reports.append($0); original?($0) }

        window.frame = CGRect(x: 0, y: 0, width: 834, height: 1210)
        spin(0.8)
        window.layoutIfNeeded()
        XCTAssertEqual(reports, [PixelSize(points: CGSize(width: 834, height: 1210), scale: scale)!])
        XCTAssertEqual(model.displaySize, PixelSize(points: CGSize(width: 834, height: 1210), scale: scale))
        assertRect(model.surface.convert(model.surface.bounds, to: window), window.bounds)
    }

    /// Old view-only hosts get no input view, so the normal pointer is never hidden.
    func testInputViewDoesNotHidePointerWhenNotForwarding() {
        let view = RemoteInputView()
        view.frame = CGRect(x: 0, y: 0, width: 1210, height: 834)
        view.videoSize = CGSize(width: 2420, height: 1668)
        view.layoutIfNeeded()
        XCTAssertFalse(view.hidesPointer(at: CGPoint(x: 605, y: 417)))
    }
}
