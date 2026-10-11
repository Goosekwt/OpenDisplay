import Foundation

/// Input waiting to be sealed and sent. Bounded, and shaped so high-rate events never crowd out releases:
/// consecutive pointer moves collapse to the latest, consecutive wheel steps add up, and when full the
/// oldest move, wheel or text goes first. Releases are never dropped; if releases alone fill it, the queue
/// collapses to one `releaseAll`. Use from the session queue only.
struct InputOutbox {
    static let capacity = 128

    private(set) var events: [InputEvent] = []

    var isEmpty: Bool { events.isEmpty }
    var count: Int { events.count }

    mutating func append(_ event: InputEvent) {
        switch (events.last, event) {
        case (.pointer(_, _, .move, _)?, .pointer(_, _, .move, _)):
            events[events.count - 1] = event
            return
        case let (.wheel(dx0, dy0)?, .wheel(dx1, dy1)):
            let dx = dx0 + dx1, dy = dy0 + dy1
            if InputEvent.wheelRange.contains(dx), InputEvent.wheelRange.contains(dy) {
                events[events.count - 1] = .wheel(dx: dx, dy: dy)
                return
            }
        default:
            break
        }
        events.append(event)
        trim()
    }

    mutating func popFirst() -> InputEvent? {
        events.isEmpty ? nil : events.removeFirst()
    }

    mutating func removeAll() {
        events.removeAll()
    }

    private mutating func trim() {
        while events.count > Self.capacity {
            if let index = events.firstIndex(where: \.isDisposable) {
                events.remove(at: index)
            } else if let index = events.firstIndex(where: { !$0.isRelease }) {
                // A press without its event is harmless; its release still follows.
                events.remove(at: index)
            } else {
                events = [.releaseAll]
            }
        }
    }
}

private extension InputEvent {
    var isDisposable: Bool {
        switch self {
        case .pointer(_, _, .move, _), .wheel, .text: true
        default: false
        }
    }
}
