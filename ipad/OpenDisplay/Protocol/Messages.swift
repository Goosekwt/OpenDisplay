import CoreGraphics
import Foundation
import SwiftUI

/// Largest JSON control message accepted (hello, identify, error).
let maximumControlMessageSize = 64 * 1024

/// Type 1 from Windows: `{"name":"PC","width":1600,"height":1000,"fps":30,"transport":"USB","ipadEdge":"left"}`.
/// Newer hosts add `"inputVersion":1` (accepts type 5 input) and `"receiverStatsVersion":1` (heartbeat stats).
struct WindowsHello: Decodable, Equatable {
    var name: String?
    var width: Int?
    var height: Int?
    var fps: Double?
    var transport: String?
    var ipadEdge: String?
    var inputVersion: Int?
    var receiverStatsVersion: Int?

    static func decode(_ payload: Data) -> WindowsHello? {
        guard payload.count <= maximumControlMessageSize else { return nil }
        return try? JSONDecoder().decode(WindowsHello.self, from: payload)
    }

    var connectionKind: ConnectionKind? { transport.flatMap(ConnectionKind.init(protocolValue:)) }
    var edge: ScreenEdge? { ipadEdge.flatMap(ScreenEdge.init(protocolValue:)) }
    var acceptsInput: Bool { inputVersion == InputEvent.protocolVersion }
    var wantsReceiverStats: Bool { receiverStatsVersion == ReceiverStats.protocolVersion }

    /// The PC display size from the hello, a stand-in for the picture size until the first frame decodes.
    var displaySize: CGSize? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }
}

/// The video viewport in physical pixels, in its current orientation, bounded per the protocol.
struct PixelSize: Equatable, CustomStringConvertible {
    static let axisRange = 320...8192

    let width: Int
    let height: Int

    init(width: Int, height: Int) {
        self.width = min(max(width, Self.axisRange.lowerBound), Self.axisRange.upperBound)
        self.height = min(max(height, Self.axisRange.lowerBound), Self.axisRange.upperBound)
    }

    /// Nil until the view has a real size.
    init?(points: CGSize, scale: CGFloat) {
        guard points.width > 0, points.height > 0, scale > 0, points.width.isFinite, points.height.isFinite else { return nil }
        self.init(width: Int((points.width * scale).rounded()), height: Int((points.height * scale).rounded()))
    }

    var description: String { "\(width) × \(height)" }
}

/// Type 1 from the iPad, sent right after authentication:
/// `{"name":"iPad","deviceId":"persistent UUID","ready":true,"displayWidth":2420,"displayHeight":1668}`.
/// The host sizes its virtual display from `displayWidth`/`displayHeight`; nil values are omitted.
struct IPadHello: Encodable, Equatable {
    var name: String
    var deviceId: String
    var ready: Bool
    var displayWidth: Int? = nil
    var displayHeight: Int? = nil

    func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data("{}".utf8)
    }
}

/// Type 3: `{"edge":"left","seconds":3}`.
struct IdentifyRequest: Decodable, Equatable {
    static let defaultSeconds: Double = 3
    static let secondsRange: ClosedRange<Double> = 1...10

    var edge: String
    var seconds: Double?

    static func decode(_ payload: Data) -> IdentifyRequest? {
        guard payload.count <= maximumControlMessageSize else { return nil }
        return try? JSONDecoder().decode(IdentifyRequest.self, from: payload)
    }

    var screenEdge: ScreenEdge? { ScreenEdge(protocolValue: edge) }

    /// Seconds clamped to a sane on-screen time; missing or non-finite values use the default.
    var duration: TimeInterval {
        guard let seconds, seconds.isFinite else { return Self.defaultSeconds }
        return min(max(seconds, Self.secondsRange.lowerBound), Self.secondsRange.upperBound)
    }
}

/// Type 6: `{"message":"..."}`. Shown to the user, so it is cleaned and length-limited.
struct RemoteErrorMessage: Decodable {
    var message: String?

    static func displayText(from payload: Data) -> String? {
        guard payload.count <= maximumControlMessageSize,
              let raw = try? JSONDecoder().decode(RemoteErrorMessage.self, from: payload).message
        else { return nil }
        let cleaned = String(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : String(cleaned.prefix(200))
    }
}

enum ConnectionKind: String, Equatable {
    case usb = "USB"
    case wifi = "Wi-Fi"

    init?(protocolValue: String) {
        switch protocolValue.trimmingCharacters(in: .whitespaces).lowercased() {
        case "usb": self = .usb
        case "wi-fi", "wifi": self = .wifi
        default: return nil
        }
    }

    var systemImage: String {
        switch self {
        case .usb: "cable.connector"
        case .wifi: "wifi"
        }
    }
}

/// An edge of the iPad screen, in physical (never right-to-left mirrored) terms.
/// The arrow sits at this edge and points outward, toward the PC's display.
enum ScreenEdge: String, CaseIterable, Equatable {
    case left, right, top, bottom

    init?(protocolValue: String) {
        self.init(rawValue: protocolValue.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// Placement inside a container whose layout direction is forced to left-to-right.
    var alignment: Alignment {
        switch self {
        case .left: .leading
        case .right: .trailing
        case .top: .top
        case .bottom: .bottom
        }
    }

    var transitionEdge: Edge {
        switch self {
        case .left: .leading
        case .right: .trailing
        case .top: .top
        case .bottom: .bottom
        }
    }

    /// Outward direction in screen coordinates (y grows downward).
    var outwardVector: CGVector {
        switch self {
        case .left: CGVector(dx: -1, dy: 0)
        case .right: CGVector(dx: 1, dy: 0)
        case .top: CGVector(dx: 0, dy: -1)
        case .bottom: CGVector(dx: 0, dy: 1)
        }
    }

    var symbolName: String {
        switch self {
        case .left: "arrow.left"
        case .right: "arrow.right"
        case .top: "arrow.up"
        case .bottom: "arrow.down"
        }
    }

    var spokenPosition: String {
        switch self {
        case .left: "to the left of this iPad"
        case .right: "to the right of this iPad"
        case .top: "above this iPad"
        case .bottom: "below this iPad"
        }
    }
}

/// One temporary arrow on screen. A new request (new id) restarts the timer.
struct EdgeArrowRequest: Equatable, Identifiable {
    let id = UUID()
    let edge: ScreenEdge
    let duration: TimeInterval

    static func forHello(_ hello: WindowsHello) -> EdgeArrowRequest? {
        hello.edge.map { EdgeArrowRequest(edge: $0, duration: IdentifyRequest.defaultSeconds) }
    }

    static func forIdentify(_ request: IdentifyRequest) -> EdgeArrowRequest? {
        request.screenEdge.map { EdgeArrowRequest(edge: $0, duration: request.duration) }
    }
}
