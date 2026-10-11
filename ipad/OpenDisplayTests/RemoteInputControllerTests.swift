import CoreGraphics
import UIKit
import XCTest
@testable import OpenDisplay

/// Virtual time for the controller's long-press, key-repeat and text-deferral timers.
final class ManualScheduler: InputScheduler {
    final class Item: InputScheduled {
        let due: TimeInterval
        let work: () -> Void
        var cancelled = false
        init(due: TimeInterval, work: @escaping () -> Void) { self.due = due; self.work = work }
        func cancel() { cancelled = true }
    }

    private(set) var now: TimeInterval = 100
    private var items: [Item] = []

    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> InputScheduled {
        let item = Item(due: now + delay, work: work)
        items.append(item)
        return item
    }

    func advance(by interval: TimeInterval) {
        let target = now + interval
        while let next = items.filter({ !$0.cancelled && $0.due <= target }).min(by: { $0.due < $1.due }) {
            items.removeAll { $0 === next }
            now = max(now, next.due)
            next.work()
        }
        items.removeAll { $0.cancelled }
        now = target
    }
}

final class RemoteInputControllerTests: XCTestCase {
    private var scheduler: ManualScheduler!
    private var controller: RemoteInputController!
    private var sent: [InputEvent] = []

    /// 1600 × 1000 picture letterboxed in an 800 × 600 view: content y 50...550.
    override func setUp() {
        super.setUp()
        scheduler = ManualScheduler()
        controller = RemoteInputController(scheduler: scheduler, now: { [unowned self] in self.scheduler.now })
        controller.geometry = VideoContentGeometry(videoSize: CGSize(width: 1600, height: 1000),
                                                   bounds: CGRect(x: 0, y: 0, width: 800, height: 600))
        controller.send = { [unowned self] in self.sent.append($0) }
        controller.setActive(true)
        sent = []
    }

    private func pointer(_ x: Double, _ y: Double, _ phase: InputEvent.PointerPhase,
                         _ button: InputEvent.PointerButton = .left) -> InputEvent {
        .pointer(x: x, y: y, phase: phase, button: button)
    }

    // MARK: Touch

    func testTapClicksAtTheTouchPoint() {
        controller.directTouchBegan(at: CGPoint(x: 400, y: 300))
        scheduler.advance(by: 0.1)
        controller.directTouchMoved(to: CGPoint(x: 403, y: 302))  // within slop
        controller.directTouchEnded(at: CGPoint(x: 403, y: 302))
        XCTAssertEqual(sent, [pointer(0.5, 0.5, .down), pointer(0.5, 0.5, .up)])
    }

    func testDragHoldsTheLeftButtonAndClampsOutsideThePicture() {
        controller.directTouchBegan(at: CGPoint(x: 200, y: 300))
        controller.directTouchMoved(to: CGPoint(x: 400, y: 300))
        controller.directTouchMoved(to: CGPoint(x: 900, y: 700))
        scheduler.advance(by: 2)  // no long press once dragging
        controller.directTouchEnded(at: CGPoint(x: 900, y: 700))
        XCTAssertEqual(sent, [pointer(0.25, 0.5, .down), pointer(0.5, 0.5, .move), pointer(1, 1, .move), pointer(1, 1, .up)])
    }

    func testLongPressIsARightClick() {
        controller.directTouchBegan(at: CGPoint(x: 400, y: 300))
        scheduler.advance(by: 0.6)
        XCTAssertEqual(sent, [pointer(0.5, 0.5, .down, .right), pointer(0.5, 0.5, .up, .right)])
        controller.directTouchMoved(to: CGPoint(x: 600, y: 300))
        controller.directTouchEnded(at: CGPoint(x: 600, y: 300))
        XCTAssertEqual(sent.count, 2, "nothing more after the right click")
    }

    func testTouchOnLetterboxIsIgnoredUntilLifted() {
        controller.directTouchBegan(at: CGPoint(x: 400, y: 20))
        controller.directTouchMoved(to: CGPoint(x: 400, y: 300))
        scheduler.advance(by: 1)
        controller.directTouchEnded(at: CGPoint(x: 400, y: 300))
        XCTAssertEqual(sent, [])
        controller.directTouchBegan(at: CGPoint(x: 400, y: 300))
        controller.directTouchEnded(at: CGPoint(x: 400, y: 300))
        XCTAssertEqual(sent.count, 2)
    }

    func testCancelledTouchNeverClicksAndReleasesADrag() {
        controller.directTouchBegan(at: CGPoint(x: 400, y: 300))
        controller.directTouchCancelled()  // e.g. a system edge swipe took it
        scheduler.advance(by: 1)
        XCTAssertEqual(sent, [])

        controller.directTouchBegan(at: CGPoint(x: 400, y: 300))
        controller.directTouchMoved(to: CGPoint(x: 500, y: 300))
        controller.directTouchCancelled()
        XCTAssertEqual(sent.last, .releaseAll)
    }

    func testSecondTapNearTheFirstHitsTheSameSpot() {
        controller.directTouchBegan(at: CGPoint(x: 400, y: 300))
        controller.directTouchEnded(at: CGPoint(x: 400, y: 300))
        scheduler.advance(by: 0.2)
        controller.directTouchBegan(at: CGPoint(x: 408, y: 306))
        controller.directTouchEnded(at: CGPoint(x: 408, y: 306))
        XCTAssertEqual(sent, [pointer(0.5, 0.5, .down), pointer(0.5, 0.5, .up), pointer(0.5, 0.5, .down), pointer(0.5, 0.5, .up)])
    }

    // MARK: Trackpad

    func testTrackpadHoverClickDragAndSecondaryClick() {
        controller.pointerHovered(at: CGPoint(x: 400, y: 300))
        controller.pointerHovered(at: CGPoint(x: 400, y: 10))  // over the bar: no move
        controller.pointerButtonBegan(.left, at: CGPoint(x: 200, y: 300))
        controller.pointerHovered(at: CGPoint(x: 0, y: 0))  // no hover while a button is down
        controller.pointerMoved(to: CGPoint(x: 400, y: 300))
        controller.pointerButtonEnded(at: CGPoint(x: 400, y: 300))
        controller.pointerButtonBegan(.right, at: CGPoint(x: 400, y: 300))
        controller.pointerButtonEnded(at: CGPoint(x: 400, y: 300))
        XCTAssertEqual(sent, [
            pointer(0.5, 0.5, .move),
            pointer(0.25, 0.5, .down), pointer(0.5, 0.5, .move), pointer(0.5, 0.5, .up),
            pointer(0.5, 0.5, .down, .right), pointer(0.5, 0.5, .up, .right),
        ])
    }

    func testScrollDirectionAndRemainder() {
        // Fingers moving down (content follows) scrolls up: positive dy. Fingers left scrolls right: positive dx.
        controller.scrolled(by: CGPoint(x: 0, y: 60))
        controller.scrolled(by: CGPoint(x: -10, y: 0))
        controller.scrolled(by: CGPoint(x: 0, y: -0.2))
        controller.scrolled(by: CGPoint(x: 0, y: -0.2))
        controller.scrolled(by: CGPoint(x: 0, y: -0.2))
        controller.scrollEnded()
        controller.scrolled(by: CGPoint(x: 0, y: 2000))
        XCTAssertEqual(sent, [.wheel(dx: 0, dy: 120), .wheel(dx: 20, dy: 0), .wheel(dx: 0, dy: -1), .wheel(dx: 0, dy: 1200)])
    }

    // MARK: Keyboard

    func testKeysModifiersAndRepeat() {
        XCTAssertTrue(controller.keyDown(HIDUsage.leftGUI))
        XCTAssertTrue(controller.keyDown(HIDUsage.backspace))
        scheduler.advance(by: 0.5 + 3.0 / 30 + 0.001)
        XCTAssertTrue(controller.keyUp(HIDUsage.backspace))
        scheduler.advance(by: 1)
        XCTAssertTrue(controller.keyUp(HIDUsage.leftGUI))
        let backspaceDown = InputEvent.key(code: HIDUsage.backspace, down: true)
        XCTAssertEqual(sent, [
            .key(code: HIDUsage.leftGUI, down: true),
            backspaceDown, backspaceDown, backspaceDown, backspaceDown, backspaceDown,  // press + 4 repeats
            .key(code: HIDUsage.backspace, down: false),
            .key(code: HIDUsage.leftGUI, down: false),
        ])
        XCTAssertFalse(controller.keyDown(0), "unknown usages go back to the responder chain")
    }

    func testModifiersDoNotRepeatAndNewKeyTakesOverRepeat() {
        controller.keyDown(HIDUsage.leftShift)
        controller.keyDown(HIDUsage.a)
        controller.keyDown(HIDUsage.rightArrow)
        scheduler.advance(by: 0.5 + 0.001)
        XCTAssertEqual(sent.last, .key(code: HIDUsage.rightArrow, down: true))
        XCTAssertEqual(sent.filter { $0 == .key(code: HIDUsage.a, down: true) }.count, 1)
        XCTAssertEqual(sent.filter { $0 == .key(code: HIDUsage.leftShift, down: true) }.count, 1)
    }

    func testDeactivatingReleasesEverythingAndStopsRepeat() {
        controller.keyDown(HIDUsage.a)
        controller.directTouchBegan(at: CGPoint(x: 400, y: 300))
        controller.directTouchMoved(to: CGPoint(x: 500, y: 300))
        controller.setActive(false)
        XCTAssertEqual(sent.last, .releaseAll)
        let count = sent.count
        scheduler.advance(by: 2)
        controller.keyDown(HIDUsage.a)
        controller.directTouchEnded(at: CGPoint(x: 500, y: 300))
        controller.scrolled(by: CGPoint(x: 0, y: 100))
        XCTAssertEqual(sent.count, count, "nothing is forwarded while inactive")
    }

    func testFocusLossReleasesHeldKeys() {
        controller.keyDown(HIDUsage.leftControl)
        controller.focusLost()
        XCTAssertEqual(sent.last, .releaseAll)
        XCTAssertTrue(controller.heldKeys.isEmpty)
        controller.keyUp(HIDUsage.leftControl)
        XCTAssertEqual(sent.last, .releaseAll, "no stray key up after the release")
    }

    // MARK: Software keyboard

    func testSoftwareTextReturnTabAndDelete() {
        controller.softwareText("hi\nthere\t")
        controller.softwareDeleteBackward()
        XCTAssertEqual(sent, [], "deferred one turn")
        scheduler.advance(by: 0)
        XCTAssertEqual(sent, [
            .text("hi"),
            .key(code: HIDUsage.returnOrEnter, down: true), .key(code: HIDUsage.returnOrEnter, down: false),
            .text("there"),
            .key(code: HIDUsage.tab, down: true), .key(code: HIDUsage.tab, down: false),
            .key(code: HIDUsage.backspace, down: true), .key(code: HIDUsage.backspace, down: false),
        ])
    }

    func testPhysicalKeyTextIsNotDuplicated() {
        // Text reported before the press in the same turn, then while held (key repeat), then just after release.
        controller.softwareText("a")
        controller.keyDown(HIDUsage.a)
        scheduler.advance(by: 0)
        controller.softwareText("a")
        scheduler.advance(by: 0)
        controller.keyUp(HIDUsage.a)
        controller.softwareText("a")
        controller.softwareDeleteBackward()
        scheduler.advance(by: 0)
        XCTAssertEqual(sent, [.key(code: HIDUsage.a, down: true), .key(code: HIDUsage.a, down: false)])

        // Holding only a modifier doesn't block on-screen typing once the window has passed.
        controller.keyDown(HIDUsage.leftShift)
        scheduler.advance(by: 1)
        controller.softwareText("B")
        scheduler.advance(by: 0)
        XCTAssertEqual(sent.last, .text("B"))
    }
}
