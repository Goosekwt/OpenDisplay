import CoreGraphics
import UIKit
import XCTest
@testable import OpenDisplay

/// Wire format, limits, capability flags, key mapping, geometry and queue shaping for remote input.
final class InputProtocolTests: XCTestCase {
    private func json(_ event: InputEvent) throws -> [String: Any] {
        let data = try XCTUnwrap(event.encoded(), "\(event) did not encode")
        XCTAssertLessThanOrEqual(data.count, InputEvent.maximumPayload)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: Encoding

    func testPointerEncoding() throws {
        let object = try json(.pointer(x: 0.25, y: 0.75, phase: .down, button: .right))
        XCTAssertEqual(object["kind"] as? String, "pointer")
        XCTAssertEqual(object["x"] as? Double, 0.25)
        XCTAssertEqual(object["y"] as? Double, 0.75)
        XCTAssertEqual(object["phase"] as? String, "down")
        XCTAssertEqual(object["button"] as? Int, 1)
        XCTAssertEqual(object.count, 5)

        let clamped = try json(.pointer(x: -0.2, y: 1.7, phase: .move, button: .left))
        XCTAssertEqual(clamped["x"] as? Double, 0)
        XCTAssertEqual(clamped["y"] as? Double, 1)
        XCTAssertEqual(try json(.pointer(x: 0.5, y: 0.5, phase: .up, button: .middle))["button"] as? Int, 2)
        XCTAssertNil(InputEvent.pointer(x: .nan, y: 0, phase: .move, button: .left).encoded())
    }

    func testWheelEncodingIsBounded() throws {
        let object = try json(.wheel(dx: -5000, dy: 120))
        XCTAssertEqual(object["kind"] as? String, "wheel")
        XCTAssertEqual(object["dx"] as? Int, -1200)
        XCTAssertEqual(object["dy"] as? Int, 120)
    }

    func testKeyEncodingAndMapping() throws {
        let object = try json(.key(code: HIDUsage.a, down: true))
        XCTAssertEqual(object["kind"] as? String, "key")
        XCTAssertEqual(object["code"] as? Int, 4)
        XCTAssertEqual(object["down"] as? Bool, true)
        XCTAssertEqual(try json(.key(code: HIDUsage.rightGUI, down: false))["code"] as? Int, 0xE7)

        // UIKit's keyboard usages are the HID usages the protocol uses.
        XCTAssertEqual(UIKeyboardHIDUsage.keyboardA.rawValue, HIDUsage.a)
        XCTAssertEqual(UIKeyboardHIDUsage.keyboardReturnOrEnter.rawValue, HIDUsage.returnOrEnter)
        XCTAssertEqual(UIKeyboardHIDUsage.keyboardDeleteOrBackspace.rawValue, HIDUsage.backspace)
        XCTAssertEqual(UIKeyboardHIDUsage.keyboardTab.rawValue, HIDUsage.tab)
        XCTAssertEqual(UIKeyboardHIDUsage.keyboardLeftArrow.rawValue, HIDUsage.leftArrow)
        XCTAssertEqual(UIKeyboardHIDUsage.keyboardUpArrow.rawValue, HIDUsage.upArrow)
        XCTAssertEqual(UIKeyboardHIDUsage.keyboardLeftControl.rawValue, HIDUsage.leftControl)
        XCTAssertEqual(UIKeyboardHIDUsage.keyboardLeftGUI.rawValue, HIDUsage.leftGUI)
        XCTAssertEqual(UIKeyboardHIDUsage.keyboardRightAlt.rawValue, HIDUsage.rightAlt)

        for usage in 0...3 { XCTAssertNil(InputEvent.key(code: usage, down: true).encoded()) }
        XCTAssertNil(InputEvent.key(code: 0xE8, down: true).encoded())
        XCTAssertTrue(HIDUsage.isModifier(HIDUsage.leftShift))
        XCTAssertFalse(HIDUsage.repeats(HIDUsage.leftShift))
        XCTAssertFalse(HIDUsage.repeats(0x39))  // Caps Lock
        XCTAssertTrue(HIDUsage.repeats(HIDUsage.backspace))
        XCTAssertTrue(HIDUsage.repeats(HIDUsage.rightArrow))
    }

    func testTextAndReleaseAllEncoding() throws {
        let object = try json(.text("héllo \"quoted\" / 👋🏽"))
        XCTAssertEqual(object["kind"] as? String, "text")
        XCTAssertEqual(object["text"] as? String, "héllo \"quoted\" / 👋🏽")
        XCTAssertEqual(try json(.releaseAll) as NSDictionary, ["kind": "releaseAll"])
        XCTAssertNil(InputEvent.text("").encoded())
        XCTAssertNil(InputEvent.text(String(repeating: "a", count: 1025)).encoded())
        XCTAssertNotNil(InputEvent.text(String(repeating: "a", count: 1024)).encoded())
    }

    func testLongTextSplitsWithinLimitsWithoutBreakingCharacters() throws {
        let long = String(repeating: "a", count: 3000)
        XCTAssertEqual(InputEvent.textEvents(for: long).map { if case .text(let t) = $0 { t.count } else { -1 } }, [1024, 1024, 952])

        let emoji = String(repeating: "👨‍👩‍👧", count: 400)  // 8 UTF-16 units per family
        let emojiEvents = InputEvent.textEvents(for: emoji)
        XCTAssertEqual(emojiEvents.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined(), emoji)

        let controls = String(repeating: "\u{01}", count: 1000)  // 6 bytes each once escaped
        let controlEvents = InputEvent.textEvents(for: controls)
        XCTAssertGreaterThan(controlEvents.count, 1)
        for event in emojiEvents + controlEvents {
            let data = try XCTUnwrap(event.encoded())
            XCTAssertLessThanOrEqual(data.count, InputEvent.maximumPayload)
        }
        XCTAssertEqual(InputEvent.textEvents(for: ""), [])
    }

    // MARK: Capabilities

    func testHelloCapabilities() throws {
        let old = try XCTUnwrap(WindowsHello.decode(Data(#"{"name":"PC","width":1600,"height":1000}"#.utf8)))
        XCTAssertFalse(old.acceptsInput)
        XCTAssertFalse(old.wantsReceiverStats)
        XCTAssertEqual(old.displaySize, CGSize(width: 1600, height: 1000))

        let new = try XCTUnwrap(WindowsHello.decode(Data(#"{"name":"PC","inputVersion":1,"receiverStatsVersion":1}"#.utf8)))
        XCTAssertTrue(new.acceptsInput)
        XCTAssertTrue(new.wantsReceiverStats)
        XCTAssertNil(new.displaySize)

        let future = try XCTUnwrap(WindowsHello.decode(Data(#"{"inputVersion":2,"receiverStatsVersion":0}"#.utf8)))
        XCTAssertFalse(future.acceptsInput)
        XCTAssertFalse(future.wantsReceiverStats)
    }

    func testReceiverStatsEncoding() throws {
        let data = ReceiverStats(enqueuedFrames: 123, droppedFrames: 0).encoded()
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"enqueuedFrames":123,"droppedFrames":0}"#)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Int])
        XCTAssertEqual(object, ["enqueuedFrames": 123, "droppedFrames": 0])
    }

    // MARK: Geometry

    func testAspectFitMappingIgnoresLetterbox() throws {
        // 16:10 picture in a 4:3 view: bars above and below.
        let geometry = try XCTUnwrap(VideoContentGeometry(videoSize: CGSize(width: 1600, height: 1000),
                                                         bounds: CGRect(x: 0, y: 0, width: 800, height: 600)))
        XCTAssertEqual(geometry.contentRect, CGRect(x: 0, y: 50, width: 800, height: 500))
        XCTAssertEqual(geometry.normalizedInside(CGPoint(x: 400, y: 300)), CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(geometry.normalizedInside(CGPoint(x: 0, y: 50)), CGPoint(x: 0, y: 0))
        XCTAssertEqual(geometry.normalizedInside(CGPoint(x: 800, y: 550)), CGPoint(x: 1, y: 1))
        XCTAssertNil(geometry.normalizedInside(CGPoint(x: 400, y: 20)), "top bar")
        XCTAssertNil(geometry.normalizedInside(CGPoint(x: 400, y: 580)), "bottom bar")
        XCTAssertEqual(geometry.normalizedClamped(CGPoint(x: -30, y: 590)), CGPoint(x: 0, y: 1))

        // Tall picture in a wide view: pillarbox.
        let pillar = try XCTUnwrap(VideoContentGeometry(videoSize: CGSize(width: 1000, height: 2000),
                                                       bounds: CGRect(x: 0, y: 0, width: 1000, height: 1000)))
        XCTAssertEqual(pillar.contentRect, CGRect(x: 250, y: 0, width: 500, height: 1000))
        XCTAssertNil(pillar.normalizedInside(CGPoint(x: 100, y: 500)))
        XCTAssertEqual(pillar.normalizedInside(CGPoint(x: 375, y: 250)), CGPoint(x: 0.25, y: 0.25))

        XCTAssertNil(VideoContentGeometry(videoSize: .zero, bounds: CGRect(x: 0, y: 0, width: 10, height: 10)))
        XCTAssertNil(VideoContentGeometry(videoSize: CGSize(width: 10, height: 10), bounds: .zero))
    }

    // MARK: Outbox

    func testOutboxCoalescesMovesAndWheel() {
        var outbox = InputOutbox()
        for i in 0..<100 { outbox.append(.pointer(x: Double(i) / 100, y: 0, phase: .move, button: .left)) }
        XCTAssertEqual(outbox.events, [.pointer(x: 0.99, y: 0, phase: .move, button: .left)])

        outbox.append(.pointer(x: 0.5, y: 0.5, phase: .down, button: .left))
        outbox.append(.pointer(x: 0.6, y: 0.5, phase: .move, button: .left))
        outbox.append(.pointer(x: 0.7, y: 0.5, phase: .move, button: .left))
        outbox.append(.pointer(x: 0.7, y: 0.5, phase: .up, button: .left))
        XCTAssertEqual(outbox.count, 4, "moves never jump over a button event")

        outbox.removeAll()
        outbox.append(.wheel(dx: 0, dy: 100))
        outbox.append(.wheel(dx: 10, dy: 100))
        XCTAssertEqual(outbox.events, [.wheel(dx: 10, dy: 200)])
        outbox.append(.wheel(dx: 0, dy: 1100))
        XCTAssertEqual(outbox.events, [.wheel(dx: 10, dy: 200), .wheel(dx: 0, dy: 1100)], "never exceeds the per-event bound")
    }

    func testOutboxIsBoundedAndKeepsReleases() {
        var outbox = InputOutbox()
        for i in 0..<1000 {
            outbox.append(.key(code: HIDUsage.a, down: true))
            outbox.append(.wheel(dx: 0, dy: i % 2 == 0 ? 1200 : -1200))
            outbox.append(.text("x"))
            XCTAssertLessThanOrEqual(outbox.count, InputOutbox.capacity)
        }
        outbox.append(.key(code: HIDUsage.a, down: false))
        outbox.append(.pointer(x: 0, y: 0, phase: .up, button: .left))
        for _ in 0..<500 { outbox.append(.wheel(dx: 1200, dy: 0)); outbox.append(.text("y")) }
        XCTAssertLessThanOrEqual(outbox.count, InputOutbox.capacity)
        XCTAssertTrue(outbox.events.contains(.key(code: HIDUsage.a, down: false)))
        XCTAssertTrue(outbox.events.contains(.pointer(x: 0, y: 0, phase: .up, button: .left)))

        var releases = InputOutbox()
        for _ in 0...InputOutbox.capacity { releases.append(.key(code: HIDUsage.a, down: false)) }
        XCTAssertEqual(releases.events, [.releaseAll], "a queue of nothing but releases collapses to releaseAll")
    }
}
