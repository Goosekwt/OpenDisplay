import UIKit
import XCTest
@testable import OpenDisplay

/// The real input view in a real window of the test host: focus follows `isForwarding`,
/// leaving releases everything, and geometry follows the view's bounds and the picture size.
@MainActor
final class RemoteInputViewTests: XCTestCase {
    private var window: UIWindow!

    override func setUp() async throws {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            throw XCTSkip("No window scene in the test host.")
        }
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
    }

    override func tearDown() async throws {
        window?.isHidden = true
        window = nil
    }

    private func spin(_ seconds: TimeInterval = 0.1) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    func testFocusFollowsForwardingAndLeavingReleasesEverything() throws {
        let view = RemoteInputView()
        var sent: [InputEvent] = []
        view.controller.send = { sent.append($0) }
        view.frame = window.bounds
        window.rootViewController!.view.addSubview(view)

        XCTAssertFalse(view.canBecomeFirstResponder, "not a responder until streaming to an input host")
        view.isForwarding = true
        spin()
        XCTAssertTrue(view.isFirstResponder)
        XCTAssertTrue(view.controller.isActive)

        view.videoSize = CGSize(width: 1600, height: 1000)
        view.layoutIfNeeded()
        XCTAssertEqual(view.controller.geometry?.contentRect, CGRect(x: 0, y: 50, width: 800, height: 500))

        view.controller.keyDown(HIDUsage.leftShift)
        view.isForwarding = false  // e.g. a sheet opened
        spin()
        XCTAssertFalse(view.isFirstResponder)
        XCTAssertFalse(view.controller.isActive)
        XCTAssertEqual(sent, [.key(code: HIDUsage.leftShift, down: true), .releaseAll])

        view.isForwarding = true
        spin()
        XCTAssertTrue(view.isFirstResponder, "focus returns when the sheet closes")
        view.removeFromSuperview()
        XCTAssertFalse(view.controller.isActive, "leaving the window stops forwarding")
    }

    func testSoftwareKeyboardProxyTakesAndReturnsFocus() throws {
        let view = RemoteInputView()
        view.frame = window.bounds
        window.rootViewController!.view.addSubview(view)
        view.isForwarding = true
        spin()
        XCTAssertTrue(view.isFirstResponder)

        view.toggleSoftwareKeyboard()
        spin()
        let proxy = try XCTUnwrap(view.subviews.compactMap { $0 as? SoftwareKeyboardProxy }.first)
        XCTAssertTrue(proxy.isFirstResponder)
        XCTAssertEqual(proxy.autocorrectionType, .no)
        XCTAssertTrue(view.controller.isActive)

        view.toggleSoftwareKeyboard()
        spin()
        XCTAssertFalse(proxy.isFirstResponder)
        XCTAssertTrue(view.isFirstResponder, "dismissing the keyboard returns focus to the stream")
        view.isForwarding = false
    }

    func testInactiveViewPassesTouchesAndKeysOn() {
        let view = RemoteInputView()
        var sent: [InputEvent] = []
        view.controller.send = { sent.append($0) }
        view.frame = window.bounds
        window.rootViewController!.view.addSubview(view)
        view.videoSize = CGSize(width: 800, height: 600)
        view.layoutIfNeeded()
        view.controller.directTouchBegan(at: CGPoint(x: 10, y: 10))
        view.controller.directTouchEnded(at: CGPoint(x: 10, y: 10))
        XCTAssertFalse(view.controller.keyDown(HIDUsage.a))
        XCTAssertEqual(sent, [])
    }
}
