import SwiftUI
import XCTest
@testable import OpenDisplay

final class EdgeArrowTests: XCTestCase {
    func testParsesProtocolEdgeNames() {
        XCTAssertEqual(ScreenEdge(protocolValue: "left"), .left)
        XCTAssertEqual(ScreenEdge(protocolValue: "RIGHT"), .right)
        XCTAssertEqual(ScreenEdge(protocolValue: " top "), .top)
        XCTAssertEqual(ScreenEdge(protocolValue: "bottom"), .bottom)
        XCTAssertNil(ScreenEdge(protocolValue: "center"))
        XCTAssertNil(ScreenEdge(protocolValue: ""))
        XCTAssertNil(ScreenEdge(protocolValue: "leading"))
    }

    /// The arrow sits at the requested edge and points outward, toward the other display.
    func testArrowSitsAtEdgeAndPointsOutward() {
        let expected: [(ScreenEdge, Alignment, Edge, CGVector, String)] = [
            (.left, .leading, .leading, CGVector(dx: -1, dy: 0), "arrow.left"),
            (.right, .trailing, .trailing, CGVector(dx: 1, dy: 0), "arrow.right"),
            (.top, .top, .top, CGVector(dx: 0, dy: -1), "arrow.up"),
            (.bottom, .bottom, .bottom, CGVector(dx: 0, dy: 1), "arrow.down"),
        ]
        for (edge, alignment, transitionEdge, vector, symbol) in expected {
            XCTAssertEqual(edge.alignment, alignment, "\(edge)")
            XCTAssertEqual(edge.transitionEdge, transitionEdge, "\(edge)")
            XCTAssertEqual(edge.outwardVector, vector, "\(edge)")
            XCTAssertEqual(edge.symbolName, symbol, "\(edge)")
        }
        XCTAssertEqual(Set(ScreenEdge.allCases.map(\.symbolName)).count, 4)
    }

    func testOutwardVectorPointsAwayFromScreenCentre() {
        let size = CGSize(width: 1000, height: 700)
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let anchors: [ScreenEdge: CGPoint] = [
            .left: CGPoint(x: 0, y: centre.y), .right: CGPoint(x: size.width, y: centre.y),
            .top: CGPoint(x: centre.x, y: 0), .bottom: CGPoint(x: centre.x, y: size.height),
        ]
        for edge in ScreenEdge.allCases {
            let anchor = anchors[edge]!
            let towardEdge = CGVector(dx: anchor.x - centre.x, dy: anchor.y - centre.y)
            XCTAssertGreaterThan(towardEdge.dx * edge.outwardVector.dx + towardEdge.dy * edge.outwardVector.dy, 0, "\(edge)")
        }
    }

    func testIdentifyEventShowsArrowWithClampedDuration() throws {
        func request(_ json: String) -> EdgeArrowRequest? {
            IdentifyRequest.decode(Data(json.utf8)).flatMap(EdgeArrowRequest.forIdentify)
        }
        let standard = try XCTUnwrap(request(#"{"edge":"left","seconds":3}"#))
        XCTAssertEqual(standard.edge, .left)
        XCTAssertEqual(standard.duration, 3)

        XCTAssertEqual(request(#"{"edge":"top"}"#)?.duration, IdentifyRequest.defaultSeconds)
        XCTAssertEqual(request(#"{"edge":"right","seconds":0}"#)?.duration, 1)
        XCTAssertEqual(request(#"{"edge":"bottom","seconds":3600}"#)?.duration, 10)
        XCTAssertEqual(request(#"{"edge":"bottom","seconds":1.5}"#)?.duration, 1.5)
        XCTAssertNil(request(#"{"edge":"middle","seconds":3}"#))
        XCTAssertNil(request(#"{"seconds":3}"#))
        XCTAssertNil(request("not json"))
    }

    func testSuccessfulHelloShowsArrowAtIPadEdge() throws {
        let json = #"{"name":"PC","width":1600,"height":1000,"fps":30,"transport":"USB","ipadEdge":"left"}"#
        let hello = try XCTUnwrap(WindowsHello.decode(Data(json.utf8)))
        let arrow = try XCTUnwrap(EdgeArrowRequest.forHello(hello))
        XCTAssertEqual(arrow.edge, .left)
        XCTAssertEqual(arrow.duration, IdentifyRequest.defaultSeconds)

        let wifi = try XCTUnwrap(WindowsHello.decode(Data(#"{"name":"PC","transport":"Wi-Fi","ipadEdge":"top"}"#.utf8)))
        XCTAssertEqual(wifi.connectionKind, .wifi)
        XCTAssertEqual(EdgeArrowRequest.forHello(wifi)?.edge, .top)

        let noEdge = try XCTUnwrap(WindowsHello.decode(Data(#"{"name":"PC"}"#.utf8)))
        XCTAssertNil(EdgeArrowRequest.forHello(noEdge))
    }

    func testEachRequestIsDistinctSoRepeatedEventsRestartTheTimer() {
        let first = EdgeArrowRequest(edge: .left, duration: 3)
        let second = EdgeArrowRequest(edge: .left, duration: 3)
        XCTAssertNotEqual(first.id, second.id)
    }

    func testControlMessagesRejectOversizedPayloads() {
        var big = Data(#"{"edge":"left","pad":""#.utf8)
        big.append(Data(repeating: 0x61, count: maximumControlMessageSize))
        big.append(Data(#""}"#.utf8))
        XCTAssertNil(IdentifyRequest.decode(big))
    }

    func testIPadHelloEncoding() throws {
        let data = IPadHello(name: "iPad", deviceId: "6F1D2E4C-0000-4000-8000-000000000001", ready: true).encoded()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["name"] as? String, "iPad")
        XCTAssertEqual(object["deviceId"] as? String, "6F1D2E4C-0000-4000-8000-000000000001")
        XCTAssertEqual(object["ready"] as? Bool, true)
        XCTAssertEqual(object.count, 3)
    }

    func testIPadHelloCarriesDisplaySizeForAutomaticSizing() throws {
        let identity = DisplayServer.Identity(name: "iPad", deviceId: "D", displaySize: PixelSize(width: 2420, height: 1668))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: identity.hello.encoded()) as? [String: Any])
        XCTAssertEqual(object["displayWidth"] as? Int, 2420)
        XCTAssertEqual(object["displayHeight"] as? Int, 1668)
        XCTAssertEqual(object["ready"] as? Bool, true)
    }

    func testPixelSizeUsesNativeScaleAndProtocolBounds() {
        // iPad Pro 11-inch landscape: 1210 × 834 points at 2× = 2420 × 1668 pixels.
        XCTAssertEqual(PixelSize(points: CGSize(width: 1210, height: 834), scale: 2), PixelSize(width: 2420, height: 1668))
        XCTAssertEqual(PixelSize(points: CGSize(width: 834, height: 1210), scale: 2), PixelSize(width: 1668, height: 2420))
        XCTAssertEqual(PixelSize(points: CGSize(width: 100.4, height: 5000), scale: 2), PixelSize(width: 320, height: 8192))
        XCTAssertNil(PixelSize(points: .zero, scale: 2))
        XCTAssertNil(PixelSize(points: CGSize(width: 10, height: 10), scale: 0))
    }

    func testRemoteErrorTextIsCleanedAndBounded() {
        XCTAssertEqual(RemoteErrorMessage.displayText(from: Data(#"{"message":"  Capture\nstopped  "}"#.utf8)), "Capturestopped")
        let long = String(repeating: "e", count: 500)
        XCTAssertEqual(RemoteErrorMessage.displayText(from: Data("{\"message\":\"\(long)\"}".utf8))?.count, 200)
        XCTAssertNil(RemoteErrorMessage.displayText(from: Data(#"{"message":"   "}"#.utf8)))
    }
}
