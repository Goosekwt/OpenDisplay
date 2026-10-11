import Foundation

/// Type 5 from the iPad, sent only when the Windows hello has `"inputVersion":1`.
/// Each record is one UTF-8 JSON object of at most `maximumPayload` bytes.
enum InputEvent: Equatable {
    case pointer(x: Double, y: Double, phase: PointerPhase, button: PointerButton)
    /// Windows wheel units: 120 is one notch up (dy) or right (dx).
    case wheel(dx: Int, dy: Int)
    /// A USB HID keyboard usage (page 7), e.g. A = 4, left/right modifiers 0xE0...0xE7.
    case key(code: Int, down: Bool)
    /// Committed software keyboard text.
    case text(String)
    case releaseAll

    static let protocolVersion = 1
    static let maximumPayload = 4096
    static let maximumTextUTF16 = 1024
    static let wheelRange = -1200...1200

    enum PointerPhase: String {
        case move, down, up
    }

    enum PointerButton: Int {
        case left = 0, right = 1, middle = 2
    }

    /// Releases must survive any queue pressure; moves and wheel steps may be coalesced or dropped.
    var isRelease: Bool {
        switch self {
        case .pointer(_, _, .up, _), .key(_, false), .releaseAll: true
        default: false
        }
    }

    /// Nil if the event can't be represented within the protocol limits.
    func encoded() -> Data? {
        let wire: Wire
        switch self {
        case let .pointer(x, y, phase, button):
            guard x.isFinite, y.isFinite else { return nil }
            wire = Wire(kind: "pointer", x: Self.coordinate(x), y: Self.coordinate(y), phase: phase.rawValue, button: button.rawValue)
        case let .wheel(dx, dy):
            wire = Wire(kind: "wheel", dx: Self.clampWheel(dx), dy: Self.clampWheel(dy))
        case let .key(code, down):
            guard HIDUsage.isForwardable(code) else { return nil }
            wire = Wire(kind: "key", code: code, down: down)
        case .text(let text):
            guard !text.isEmpty, text.utf16.count <= Self.maximumTextUTF16 else { return nil }
            wire = Wire(kind: "text", text: text)
        case .releaseAll:
            wire = Wire(kind: "releaseAll")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(wire), data.count <= Self.maximumPayload else { return nil }
        return data
    }

    static func clampWheel(_ value: Int) -> Int {
        min(max(value, wheelRange.lowerBound), wheelRange.upperBound)
    }

    /// Clamped to 0...1 and rounded to 1/100000, finer than any display axis.
    static func coordinate(_ value: Double) -> Double {
        (min(max(value, 0), 1) * 100_000).rounded() / 100_000
    }

    /// Splits committed text into `.text` events that each fit the UTF-16 and payload limits,
    /// never splitting a grapheme cluster. A single cluster that can't fit on its own is dropped.
    static func textEvents(for text: String) -> [InputEvent] {
        let utf16Budget = maximumTextUTF16
        let byteBudget = maximumPayload - 64  // room for `{"kind":"text","text":""}`
        var events: [InputEvent] = []
        var chunk = ""
        var chunkUTF16 = 0
        var chunkBytes = 0
        for character in text {
            let units = character.utf16.count
            let bytes = character.unicodeScalars.reduce(0) { $0 + jsonCost($1) }
            guard units <= utf16Budget, bytes <= byteBudget else { continue }
            if chunkUTF16 + units > utf16Budget || chunkBytes + bytes > byteBudget {
                events.append(.text(chunk))
                chunk = ""
                chunkUTF16 = 0
                chunkBytes = 0
            }
            chunk.append(character)
            chunkUTF16 += units
            chunkBytes += bytes
        }
        if !chunk.isEmpty { events.append(.text(chunk)) }
        return events
    }

    /// Worst-case encoded size of one scalar inside a JSON string.
    private static func jsonCost(_ scalar: Unicode.Scalar) -> Int {
        switch scalar.value {
        case 0x22, 0x5C, 0x08, 0x09, 0x0A, 0x0C, 0x0D: 2
        case 0..<0x20, 0x7F, 0x2028, 0x2029: 6
        default: String(scalar).utf8.count
        }
    }

    private struct Wire: Encodable {
        var kind: String
        var x: Double?
        var y: Double?
        var phase: String?
        var button: Int?
        var dx: Int?
        var dy: Int?
        var code: Int?
        var down: Bool?
        var text: String?
    }
}

/// USB HID keyboard usages (page 7). UIKit's `UIKeyboardHIDUsage` raw values are these usages.
enum HIDUsage {
    static let a = 0x04
    static let returnOrEnter = 0x28
    static let escape = 0x29
    static let backspace = 0x2A
    static let tab = 0x2B
    static let rightArrow = 0x4F
    static let leftArrow = 0x50
    static let downArrow = 0x51
    static let upArrow = 0x52
    static let leftControl = 0xE0
    static let leftShift = 0xE1
    static let leftAlt = 0xE2   // Option
    static let leftGUI = 0xE3   // Command
    static let rightControl = 0xE4
    static let rightShift = 0xE5
    static let rightAlt = 0xE6
    static let rightGUI = 0xE7

    /// Keyboard keys (A through the international/language block) and the eight modifiers.
    /// 0...3 are error/reserved codes and are never forwarded.
    static func isForwardable(_ usage: Int) -> Bool {
        (a...0xA4).contains(usage) || isModifier(usage)
    }

    static func isModifier(_ usage: Int) -> Bool {
        (leftControl...rightGUI).contains(usage)
    }

    /// Modifiers and lock keys don't auto-repeat.
    static func repeats(_ usage: Int) -> Bool {
        isForwardable(usage) && !isModifier(usage) && usage != 0x39 && usage != 0x53 && usage != 0x47
    }
}

/// Heartbeat reply for hosts whose hello has `"receiverStatsVersion":1`.
/// Counts frames the pipeline accepted for display this session, not actual screen scanout.
struct ReceiverStats: Equatable {
    static let protocolVersion = 1

    var enqueuedFrames: Int
    var droppedFrames: Int

    func encoded() -> Data {
        Data(#"{"enqueuedFrames":\#(enqueuedFrames),"droppedFrames":\#(droppedFrames)}"#.utf8)
    }
}
