import SwiftUI
import UIKit

/// Transparent layer over the video that forwards touch, Pencil, trackpad, mouse and keyboard input
/// to the PC through `RemoteInputController`. Only first responder while `isForwarding`.
/// System edge gestures keep priority: no edges are deferred, and a stolen touch is simply cancelled.
/// The iPad pointer is hidden over the picture, where the PC draws its own cursor, and shown everywhere else.
final class RemoteInputView: UIView, UIGestureRecognizerDelegate, UIPointerInteractionDelegate {
    let controller: RemoteInputController

    /// Streaming to an input-capable host, app active, no sheet up.
    var isForwarding = false {
        didSet {
            guard isForwarding != oldValue else { return }
            updateActivation()
            pointerInteraction.invalidate()
        }
    }

    /// Decoded picture size; the view maps through the aspect-fit rectangle inside its bounds.
    var videoSize: CGSize? {
        didSet { if videoSize != oldValue { updateGeometry() } }
    }

    private let keyboardProxy = SoftwareKeyboardProxy()
    private lazy var pointerInteraction = UIPointerInteraction(delegate: self)
    private weak var directTouch: UITouch?
    private weak var pointerTouch: UITouch?

    init(controller: RemoteInputController = RemoteInputController()) {
        self.controller = controller
        super.init(frame: .zero)
        backgroundColor = .clear
        isMultipleTouchEnabled = true

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
        hover.delegate = self
        addGestureRecognizer(hover)

        // Trackpad two-finger scroll and mouse wheel only; never touches.
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
        scroll.allowedScrollTypesMask = .all
        scroll.allowedTouchTypes = []
        scroll.delegate = self
        addGestureRecognizer(scroll)

        // Two fingers on the screen scroll too. Recognizing cancels the first finger's pending tap.
        let twoFingerScroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
        twoFingerScroll.minimumNumberOfTouches = 2
        twoFingerScroll.maximumNumberOfTouches = 2
        twoFingerScroll.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        twoFingerScroll.delegate = self
        addGestureRecognizer(twoFingerScroll)

        addInteraction(pointerInteraction)

        keyboardProxy.frame = .zero
        keyboardProxy.alpha = 0
        keyboardProxy.isAccessibilityElement = false
        keyboardProxy.onText = { [weak self] in self?.controller.softwareText($0) }
        keyboardProxy.onDeleteBackward = { [weak self] in self?.controller.softwareDeleteBackward() }
        keyboardProxy.onResign = { [weak self] in self?.reclaimFocusSoon() }
        addSubview(keyboardProxy)

        isAccessibilityElement = true
        accessibilityLabel = "PC display"
        accessibilityHint = "Touches, trackpad and keyboard control your PC."
        accessibilityTraits = .allowsDirectInteraction

        NotificationCenter.default.addObserver(self, selector: #selector(windowResignedKey(_:)),
                                               name: UIWindow.didResignKeyNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowBecameKey(_:)),
                                               name: UIWindow.didBecomeKeyNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Shows or hides the on-screen keyboard. Committed text is sent as Unicode text.
    func toggleSoftwareKeyboard() {
        guard isForwarding, window != nil else { return }
        if keyboardProxy.isFirstResponder {
            _ = keyboardProxy.resignFirstResponder()
        } else {
            _ = keyboardProxy.becomeFirstResponder()
        }
    }

    /// The controls closed (or a menu went away): take keyboard focus back if nothing else should have it.
    func reclaimFocusIfNeeded() {
        reclaimFocusSoon()
    }

    // MARK: Focus

    override var canBecomeFirstResponder: Bool { isForwarding && window != nil }

    /// Something else took keyboard focus (a menu, the on-screen keyboard): nothing may stay held.
    @discardableResult
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { controller.focusLost() }
        return resigned
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateActivation()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateGeometry()
    }

    private func updateActivation() {
        let active = isForwarding && window != nil
        controller.setActive(active)
        if active {
            reclaimFocusSoon()
        } else {
            if keyboardProxy.isFirstResponder { _ = keyboardProxy.resignFirstResponder() }
            if isFirstResponder { _ = resignFirstResponder() }
            directTouch = nil
            pointerTouch = nil
        }
    }

    private func reclaimFocusSoon() {
        DispatchQueue.main.async { [weak self] in self?.reclaimFocus() }
    }

    private func reclaimFocus() {
        guard isForwarding, window != nil, !isFirstResponder, !keyboardProxy.isFirstResponder else { return }
        becomeFirstResponder()
    }

    private func updateGeometry() {
        let geometry = videoSize.flatMap { VideoContentGeometry(videoSize: $0, bounds: bounds) }
        guard geometry != controller.geometry else { return }
        controller.geometry = geometry
        pointerInteraction.invalidate()
    }

    // MARK: Pointer

    /// The PC's capture already includes its cursor, so a visible iPad pointer over the picture would be a
    /// second cursor. Over any letterbox bars, the controls and sheets the normal pointer stays.
    func hidesPointer(at point: CGPoint) -> Bool {
        guard isForwarding, let rect = controller.geometry?.contentRect else { return false }
        return rect.contains(point)
    }

    func pointerInteraction(_ interaction: UIPointerInteraction, regionFor request: UIPointerRegionRequest,
                            defaultRegion: UIPointerRegion) -> UIPointerRegion? {
        guard hidesPointer(at: request.location), let rect = controller.geometry?.contentRect else { return nil }
        return UIPointerRegion(rect: rect, identifier: "remote-picture")
    }

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        .hidden()
    }

    @objc private func windowResignedKey(_ note: Notification) {
        guard let window, note.object as? UIWindow === window else { return }
        controller.focusLost()
    }

    @objc private func windowBecameKey(_ note: Notification) {
        guard let window, note.object as? UIWindow === window else { return }
        reclaimFocusSoon()
    }

    // MARK: Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isForwarding else { return super.touchesBegan(touches, with: event) }
        reclaimFocus()
        for touch in touches {
            switch touch.type {
            case .direct, .pencil:
                guard directTouch == nil else { continue }
                directTouch = touch
                controller.directTouchBegan(at: touch.location(in: self))
            case .indirectPointer:
                guard pointerTouch == nil else { continue }
                pointerTouch = touch
                controller.pointerButtonBegan(Self.button(for: event?.buttonMask ?? .primary), at: touch.location(in: self))
            default:
                break
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isForwarding else { return super.touchesMoved(touches, with: event) }
        for touch in touches {
            if touch === directTouch { controller.directTouchMoved(to: touch.location(in: self)) }
            if touch === pointerTouch { controller.pointerMoved(to: touch.location(in: self)) }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isForwarding else { return super.touchesEnded(touches, with: event) }
        for touch in touches {
            if touch === directTouch {
                directTouch = nil
                controller.directTouchEnded(at: touch.location(in: self))
            }
            if touch === pointerTouch {
                pointerTouch = nil
                controller.pointerButtonEnded(at: touch.location(in: self))
            }
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isForwarding else { return super.touchesCancelled(touches, with: event) }
        for touch in touches {
            if touch === directTouch {
                directTouch = nil
                controller.directTouchCancelled()
            }
            if touch === pointerTouch {
                pointerTouch = nil
                controller.pointerCancelled()
            }
        }
    }

    private static func button(for mask: UIEvent.ButtonMask) -> InputEvent.PointerButton {
        if mask.contains(.secondary) { return .right }
        if mask.contains(.button(3)) { return .middle }
        return .left
    }

    @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
        switch recognizer.state {
        case .began, .changed: controller.pointerHovered(at: recognizer.location(in: self))
        default: break
        }
    }

    @objc private func scrolled(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began, .changed:
            let translation = recognizer.translation(in: self)
            recognizer.setTranslation(.zero, in: self)
            controller.scrolled(by: translation)
        case .ended, .cancelled, .failed:
            controller.scrollEnded()
        default:
            break
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        other.view === self
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        isForwarding
    }

    // MARK: Keyboard

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = presses.filter { press in
            guard isForwarding, let key = press.key else { return true }
            return !controller.keyDown(key.keyCode.rawValue)
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = releaseKeys(presses)
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = releaseKeys(presses)
        if !unhandled.isEmpty { super.pressesCancelled(unhandled, with: event) }
    }

    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = presses.filter { press in
            guard isForwarding, let key = press.key else { return true }
            return !HIDUsage.isForwardable(key.keyCode.rawValue)
        }
        if !unhandled.isEmpty { super.pressesChanged(unhandled, with: event) }
    }

    private func releaseKeys(_ presses: Set<UIPress>) -> Set<UIPress> {
        presses.filter { press in
            guard isForwarding, let key = press.key else { return true }
            return !controller.keyUp(key.keyCode.rawValue)
        }
    }
}

/// An invisible text responder that brings up the on-screen keyboard on request. Physical key presses
/// pass through it to `RemoteInputView` via the responder chain; their duplicate text is filtered out.
final class SoftwareKeyboardProxy: UIView, UIKeyInput {
    var onText: ((String) -> Void)?
    var onDeleteBackward: (() -> Void)?
    var onResign: (() -> Void)?

    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .default
    var returnKeyType: UIReturnKeyType = .default

    override init(frame: CGRect) {
        super.init(frame: frame)
        // The shortcut bar's undo/paste buttons can't act on the PC, so hide them.
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var canBecomeFirstResponder: Bool { true }

    @discardableResult
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onResign?() }
        return resigned
    }

    /// Always true so Delete is reported even when nothing has been typed in this session.
    var hasText: Bool { true }

    func insertText(_ text: String) { onText?(text) }

    func deleteBackward() { onDeleteBackward?() }
}

/// Hosts the app's single, long-lived input view.
struct RemoteInputSurface: UIViewRepresentable {
    let view: RemoteInputView
    let isForwarding: Bool
    let videoSize: CGSize?

    func makeUIView(context: Context) -> RemoteInputView { view }

    func updateUIView(_ uiView: RemoteInputView, context: Context) {
        uiView.videoSize = videoSize
        uiView.isForwarding = isForwarding
    }
}
