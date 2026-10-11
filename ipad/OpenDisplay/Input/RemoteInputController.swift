import CoreGraphics
import Foundation

/// Delayed work, injectable so tests control time.
protocol InputScheduler {
    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> InputScheduled
}

protocol InputScheduled {
    func cancel()
}

struct MainQueueScheduler: InputScheduler {
    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> InputScheduled {
        let item = DispatchWorkItem(block: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return item
    }
}

extension DispatchWorkItem: InputScheduled {}

/// Turns touches, trackpad, scroll and keyboard input (in view points) into protocol events.
/// UIKit-free so the behaviour is unit-tested; `RemoteInputView` feeds it. Main thread only.
final class RemoteInputController {
    struct Tuning {
        var longPressDelay: TimeInterval = 0.55
        /// Movement, in points, that turns a touch into a drag (and rules out a long press).
        var dragSlop: CGFloat = 10
        var doubleTapInterval: TimeInterval = 0.5
        var doubleTapDistance: CGFloat = 24
        /// Windows wheel units per point of scroll translation.
        var wheelUnitsPerPoint: CGFloat = 2
        var keyRepeatDelay: TimeInterval = 0.5
        var keyRepeatInterval: TimeInterval = 1.0 / 30
        /// A software keyboard callback this close to a physical key press is that key's text.
        var hardwareTextWindow: TimeInterval = 0.15
    }

    var send: (InputEvent) -> Void = { _ in }
    var geometry: VideoContentGeometry?
    private(set) var isActive = false

    private let tuning: Tuning
    private let scheduler: InputScheduler
    private let now: () -> TimeInterval

    private enum TouchState {
        case idle
        case pending(start: CGPoint, normalized: CGPoint)
        case dragging
        case longPressed
        case ignored
    }

    private var touch = TouchState.idle
    private var longPressWork: InputScheduled?
    private var lastTap: (time: TimeInterval, point: CGPoint, normalized: CGPoint)?

    private var pointerButton: InputEvent.PointerButton?
    private var pointerIgnored = false
    private var scrollRemainder = CGPoint.zero

    private(set) var heldKeys = Set<Int>()
    private var repeatingKey: Int?
    private var repeatWork: InputScheduled?
    private var lastHardwareKeyDown: TimeInterval = -.infinity

    init(tuning: Tuning = Tuning(), scheduler: InputScheduler = MainQueueScheduler(),
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.tuning = tuning
        self.scheduler = scheduler
        self.now = now
    }

    /// Forward only while streaming to an input-capable host with no sheet up. Leaving releases everything.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        if !active { send(.releaseAll) }
        resetState()
        isActive = active
    }

    // MARK: Direct touch and Pencil

    /// Tap: left click at the touch-up. Drag past the slop: left button held. Hold still: right click.
    func directTouchBegan(at point: CGPoint) {
        guard isActive, case .idle = touch else { return }
        guard let normalized = geometry?.normalizedInside(point) else {
            touch = .ignored
            return
        }
        touch = .pending(start: point, normalized: normalized)
        longPressWork = scheduler.schedule(after: tuning.longPressDelay) { [weak self] in self?.longPressFired() }
    }

    func directTouchMoved(to point: CGPoint) {
        guard isActive, let geometry else { return }
        switch touch {
        case let .pending(start, normalized):
            guard hypot(point.x - start.x, point.y - start.y) > tuning.dragSlop else { return }
            cancelLongPress()
            touch = .dragging
            send(Self.pointer(normalized, .down, .left))
            send(Self.pointer(geometry.normalizedClamped(point), .move, .left))
        case .dragging:
            send(Self.pointer(geometry.normalizedClamped(point), .move, .left))
        case .idle, .longPressed, .ignored:
            break
        }
    }

    func directTouchEnded(at point: CGPoint) {
        guard isActive else { return }
        cancelLongPress()
        switch touch {
        case let .pending(start, normalized):
            var target = normalized
            let time = now()
            // A second tap near the first lands on exactly the same spot, so Windows sees a double-click.
            if let lastTap, time - lastTap.time <= tuning.doubleTapInterval,
               hypot(start.x - lastTap.point.x, start.y - lastTap.point.y) <= tuning.doubleTapDistance {
                target = lastTap.normalized
            }
            send(Self.pointer(target, .down, .left))
            send(Self.pointer(target, .up, .left))
            lastTap = (time, start, target)
        case .dragging:
            if let geometry { send(Self.pointer(geometry.normalizedClamped(point), .up, .left)) } else { send(.releaseAll) }
        case .idle, .longPressed, .ignored:
            break
        }
        touch = .idle
    }

    /// The system took the touch (an edge gesture, a second finger scrolling). Nothing stays pressed.
    func directTouchCancelled() {
        cancelLongPress()
        if case .dragging = touch, isActive { releaseEverything() }
        touch = .idle
    }

    private func longPressFired() {
        longPressWork = nil
        guard isActive, case let .pending(_, normalized) = touch else { return }
        touch = .longPressed
        send(Self.pointer(normalized, .down, .right))
        send(Self.pointer(normalized, .up, .right))
    }

    // MARK: Trackpad and mouse

    func pointerHovered(at point: CGPoint) {
        guard isActive, pointerButton == nil, let normalized = geometry?.normalizedInside(point) else { return }
        send(Self.pointer(normalized, .move, .left))
    }

    func pointerButtonBegan(_ button: InputEvent.PointerButton, at point: CGPoint) {
        guard isActive, pointerButton == nil, !pointerIgnored else { return }
        guard let normalized = geometry?.normalizedInside(point) else {
            pointerIgnored = true
            return
        }
        pointerButton = button
        send(Self.pointer(normalized, .down, button))
    }

    func pointerMoved(to point: CGPoint) {
        guard isActive, let button = pointerButton, let geometry else { return }
        send(Self.pointer(geometry.normalizedClamped(point), .move, button))
    }

    func pointerButtonEnded(at point: CGPoint) {
        defer {
            pointerButton = nil
            pointerIgnored = false
        }
        guard isActive, let button = pointerButton else { return }
        if let geometry { send(Self.pointer(geometry.normalizedClamped(point), .up, button)) } else { send(.releaseAll) }
    }

    func pointerCancelled() {
        if pointerButton != nil, isActive { releaseEverything() }
        pointerButton = nil
        pointerIgnored = false
    }

    /// `delta` is the change in scroll translation, in points (content-follows-fingers, as UIKit reports it).
    func scrolled(by delta: CGPoint) {
        guard isActive else { return }
        scrollRemainder.x -= delta.x * tuning.wheelUnitsPerPoint
        scrollRemainder.y += delta.y * tuning.wheelUnitsPerPoint
        let dx = Int(scrollRemainder.x.rounded(.towardZero))
        let dy = Int(scrollRemainder.y.rounded(.towardZero))
        guard dx != 0 || dy != 0 else { return }
        scrollRemainder.x -= CGFloat(dx)
        scrollRemainder.y -= CGFloat(dy)
        send(.wheel(dx: InputEvent.clampWheel(dx), dy: InputEvent.clampWheel(dy)))
    }

    func scrollEnded() {
        scrollRemainder = .zero
    }

    // MARK: Keyboard

    /// Returns false for keys that aren't forwarded, so the responder chain can have them.
    @discardableResult
    func keyDown(_ usage: Int) -> Bool {
        guard isActive, HIDUsage.isForwardable(usage) else { return false }
        if !HIDUsage.isModifier(usage) { lastHardwareKeyDown = now() }
        heldKeys.insert(usage)
        send(.key(code: usage, down: true))
        if HIDUsage.repeats(usage) { startRepeating(usage) }
        return true
    }

    @discardableResult
    func keyUp(_ usage: Int) -> Bool {
        guard isActive, HIDUsage.isForwardable(usage) else { return false }
        if repeatingKey == usage { stopRepeating() }
        if heldKeys.remove(usage) != nil { send(.key(code: usage, down: false)) }
        return true
    }

    /// Committed software keyboard text. Return and Tab become key taps so Windows sees real Enter/Tab.
    func softwareText(_ text: String) {
        guard isActive else { return }
        let arrived = now()
        afterHardwareCheck(arrived) { [weak self] in
            guard let self else { return }
            var pending = ""
            for character in text {
                let usage: Int? = switch character {
                case "\n", "\r", "\r\n": HIDUsage.returnOrEnter
                case "\t": HIDUsage.tab
                default: nil
                }
                if let usage {
                    InputEvent.textEvents(for: pending).forEach(self.send)
                    pending = ""
                    self.tap(usage)
                } else {
                    pending.append(character)
                }
            }
            InputEvent.textEvents(for: pending).forEach(self.send)
        }
    }

    func softwareDeleteBackward() {
        guard isActive else { return }
        afterHardwareCheck(now()) { [weak self] in self?.tap(HIDUsage.backspace) }
    }

    /// UIKit may report a physical key's text before or after the press itself, so decide on the next turn:
    /// anything while a physical key is held, or right after one went down, came from the hardware keyboard.
    private func afterHardwareCheck(_ arrived: TimeInterval, _ deliver: @escaping () -> Void) {
        _ = scheduler.schedule(after: 0) { [weak self] in
            guard let self, self.isActive else { return }
            let physicalHeld = self.heldKeys.contains { !HIDUsage.isModifier($0) }
            guard !physicalHeld, abs(arrived - self.lastHardwareKeyDown) > self.tuning.hardwareTextWindow else { return }
            deliver()
        }
    }

    private func tap(_ usage: Int) {
        send(.key(code: usage, down: true))
        send(.key(code: usage, down: false))
    }

    private func startRepeating(_ usage: Int) {
        stopRepeating()
        repeatingKey = usage
        repeatWork = scheduler.schedule(after: tuning.keyRepeatDelay) { [weak self] in self?.repeatTick(usage) }
    }

    private func repeatTick(_ usage: Int) {
        guard isActive, repeatingKey == usage, heldKeys.contains(usage) else { return }
        send(.key(code: usage, down: true))
        repeatWork = scheduler.schedule(after: tuning.keyRepeatInterval) { [weak self] in self?.repeatTick(usage) }
    }

    private func stopRepeating() {
        repeatWork?.cancel()
        repeatWork = nil
        repeatingKey = nil
    }

    // MARK: State

    /// Focus left the stream (window lost key status, first responder resigned): release keys and buttons.
    func focusLost() {
        guard isActive else { return }
        releaseEverything()
    }

    private func releaseEverything() {
        send(.releaseAll)
        resetState()
    }

    private func resetState() {
        cancelLongPress()
        stopRepeating()
        touch = .idle
        pointerButton = nil
        pointerIgnored = false
        scrollRemainder = .zero
        heldKeys.removeAll()
    }

    private func cancelLongPress() {
        longPressWork?.cancel()
        longPressWork = nil
    }

    private static func pointer(_ point: CGPoint, _ phase: InputEvent.PointerPhase,
                                _ button: InputEvent.PointerButton) -> InputEvent {
        .pointer(x: Double(point.x), y: Double(point.y), phase: phase, button: button)
    }
}
