import Observation
import SwiftUI
import UIKit

@MainActor
@Observable
final class AppModel {
    enum Status: Equatable {
        case unpaired
        case paused
        case starting
        case waiting
        case listenerFailed(String)
        case connected
        case streaming
    }

    private(set) var isPaired = false
    private(set) var pairedPCName: String?
    private(set) var isPaused = false
    private(set) var listenerStatus: ListenerStatus = .stopped
    private(set) var isConnected = false
    private(set) var hasVideo = false
    private(set) var hello: WindowsHello?
    private(set) var notice: String?
    private(set) var arrow: EdgeArrowRequest?
    private(set) var lastEdge: ScreenEdge?
    /// The video viewport in pixels. Sent to the PC so it sizes the display automatically.
    private(set) var displaySize: PixelSize?
    /// The decoded picture's size, for mapping touches through the aspect-fit rectangle.
    private(set) var decodedVideoSize: CGSize?

    let surface = VideoSurfaceView(frame: .zero)
    let remoteInput = RemoteInputView()

    @ObservationIgnored private var server: DisplayServer!
    @ObservationIgnored private let store = PairingStore()
    @ObservationIgnored private var isForeground = false
    @ObservationIgnored private var arrowTask: Task<Void, Never>?
    @ObservationIgnored private var resizeTask: Task<Void, Never>?

    init() {
        server = DisplayServer(renderer: surface.displayLayer.sampleBufferRenderer) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        let server = self.server!
        remoteInput.controller.send = { server.sendInput($0) }
        surface.onPixelSizeChange = { [weak self] size in
            MainActor.assumeIsolated { self?.viewportChanged(to: size) }
        }
        reloadPairing()
    }

    // MARK: Derived state

    var status: Status {
        if !isPaired { return .unpaired }
        if isPaused { return .paused }
        if hasVideo { return .streaming }
        if isConnected { return .connected }
        switch listenerStatus {
        case .listening: return .waiting
        case .failed(let message): return .listenerFailed(message)
        case .stopped, .starting: return .starting
        }
    }

    var displayPCName: String {
        PairingCode.sanitizedName(hello?.name) ?? pairedPCName ?? "your PC"
    }

    var connectionKind: ConnectionKind? { hello?.connectionKind }

    /// Streaming to a host that accepts touch, trackpad and keyboard input. Older hosts are view-only.
    var acceptsInput: Bool { hasVideo && hello?.acceptsInput == true }

    var videoContentSize: CGSize? { decodedVideoSize ?? hello?.displaySize }

    var connectionSummary: String {
        var parts = [displayPCName]
        if let kind = connectionKind { parts.append(kind.rawValue) }
        if let width = hello?.width, let height = hello?.height { parts.append("\(width) × \(height)") }
        return parts.joined(separator: " · ")
    }

    var statusText: String {
        switch status {
        case .unpaired: "Not paired"
        case .paused: "Paused"
        case .starting: "Starting"
        case .waiting: "Waiting for connection"
        case .listenerFailed: "Not accepting connections"
        case .connected: "Connected"
        case .streaming: "Showing display"
        }
    }

    var isAdvertisingOnWiFi: Bool {
        if case .listening(let advertising) = listenerStatus { return advertising }
        return false
    }

    // MARK: Lifecycle

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            isForeground = true
            startListeningIfPossible()
        case .background:
            isForeground = false
            server.stop()
        default:
            break  // Inactive (Control Center, app switcher peek) keeps the session.
        }
    }

    // MARK: Pairing

    func pair(with code: PairingCode) throws {
        try store.save(code)
        server.stop()
        isPaused = false
        notice = nil
        reloadPairing()
        startListeningIfPossible()
    }

    func forgetPairing() {
        server.stop()
        do {
            try store.forget()
        } catch {
            notice = error.localizedDescription
        }
        reloadPairing()
    }

    // MARK: Session controls

    func disconnectAndPause() {
        isPaused = true
        server.stop()
    }

    func resume() {
        isPaused = false
        startListeningIfPossible()
    }

    func retryListening() {
        server.stop()
        startListeningIfPossible()
    }

    func toggleSoftwareKeyboard() {
        remoteInput.toggleSoftwareKeyboard()
    }

    func showLastArrowAgain() {
        guard let lastEdge else { return }
        showArrow(EdgeArrowRequest(edge: lastEdge, duration: IdentifyRequest.defaultSeconds))
    }

    // MARK: Private

    private func reloadPairing() {
        let key = try? store.loadKey()
        isPaired = key != nil
        pairedPCName = store.pcName
    }

    private func startListeningIfPossible() {
        guard isForeground, isPaired, !isPaused else { return }
        do {
            guard let key = try store.loadKey() else {
                reloadPairing()
                return
            }
            server.start(pairingKey: key, identity: .init(name: UIDevice.current.name, deviceId: store.deviceId,
                                                          displaySize: displaySize))
        } catch {
            notice = "Couldn't read the pairing key from the Keychain."
        }
    }

    /// The first size applies at once; later ones settle for a moment so a rotation or a
    /// Stage Manager drag ends only one session.
    private func viewportChanged(to size: PixelSize) {
        resizeTask?.cancel()
        guard size != displaySize else { return }
        guard displaySize != nil else {
            applyDisplaySize(size)
            return
        }
        resizeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.applyDisplaySize(size)
        }
    }

    private func applyDisplaySize(_ size: PixelSize) {
        displaySize = size
        server.updateDisplaySize(size)
    }

    /// Internal so layout tests can drive a streaming session without a PC.
    func handle(_ event: ServerEvent) {
        switch event {
        case .listener(let status):
            listenerStatus = status
        case .sessionStarted:
            isConnected = true
            hasVideo = false
            hello = nil
            decodedVideoSize = nil
            notice = nil
            UIApplication.shared.isIdleTimerDisabled = true
        case .hello(let hello):
            self.hello = hello
            if let request = EdgeArrowRequest.forHello(hello) { showArrow(request) }
        case .identify(let request):
            if let arrowRequest = EdgeArrowRequest.forIdentify(request) { showArrow(arrowRequest) }
        case .firstFrame:
            hasVideo = true
        case .videoSize(let size):
            decodedVideoSize = size
        case .remoteError(let message):
            notice = message
        case .sessionEnded(let reason):
            isConnected = false
            hasVideo = false
            hello = nil
            decodedVideoSize = nil
            UIApplication.shared.isIdleTimerDisabled = false
            if let text = Self.noticeText(for: reason) { notice = text }
        case .authenticationFailed:
            notice = "A PC tried to connect, but its pairing key doesn't match this iPad. Pair again from the PC."
        }
    }

    private func showArrow(_ request: EdgeArrowRequest) {
        lastEdge = request.edge
        arrow = request
        UIAccessibility.post(notification: .announcement, argument: "Your PC's display is \(request.edge.spokenPosition).")

        arrowTask?.cancel()
        arrowTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(request.duration))
            guard !Task.isCancelled, let self, self.arrow?.id == request.id else { return }
            self.arrow = nil
        }
    }

    private static func noticeText(for reason: PeerConnection.CloseReason) -> String? {
        switch reason {
        case .timedOut: "The connection to your PC timed out."
        case .protocolViolation: "The connection closed because the PC sent data this version doesn't understand."
        case .networkError: "The connection to your PC was lost."
        case .remoteClosed, .replaced, .stopped, .authenticationFailed, .notOpenDisplay, .displayResized: nil
        }
    }
}
