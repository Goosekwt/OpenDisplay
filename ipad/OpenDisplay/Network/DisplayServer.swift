import AVFoundation
import CryptoKit
import Foundation
import Network
import os

enum ListenerStatus: Equatable {
    case stopped
    case starting
    case listening(advertising: Bool)
    case failed(String)
}

enum ServerEvent {
    case listener(ListenerStatus)
    case sessionStarted
    case hello(WindowsHello)
    case identify(IdentifyRequest)
    case firstFrame
    /// The decoded picture size changed (or became known).
    case videoSize(CGSize)
    case remoteError(String)
    case sessionEnded(PeerConnection.CloseReason)
    /// An OpenDisplay PC tried to connect with a different pairing key. The current session, if any, is untouched.
    case authenticationFailed
}

/// Listens on TCP 42150 (reached over USB through usbmux, or over Wi-Fi), advertises
/// `_opendisplay._tcp`, authenticates connections and keeps at most one live session.
final class DisplayServer {
    static let defaultPort: UInt16 = 42150
    static let serviceType = "_opendisplay._tcp"
    static let maximumPendingConnections = 4
    static let maximumHeartbeatPayload = 4096
    /// Input never uses more than half of PeerConnection's send window, so heartbeat replies always fit.
    static let maximumInputSendsInFlight = PeerConnection.maximumSendsInFlight / 2

    struct Identity {
        var name: String
        var deviceId: String
        var displaySize: PixelSize? = nil

        var hello: IPadHello {
            IPadHello(name: name, deviceId: deviceId, ready: true,
                      displayWidth: displaySize?.width, displayHeight: displaySize?.height)
        }
    }

    private static let log = Logger(subsystem: "me.talsa.OpenDisplay", category: "session")

    private let port: UInt16
    private let queue = DispatchQueue(label: "me.talsa.OpenDisplay.session", qos: .userInteractive)
    private let video: VideoPipeline
    private let events: (ServerEvent) -> Void

    private var listener: NWListener?
    private var advertise: Bool
    private var advertiseRequested: Bool
    private var pairingKey: SymmetricKey?
    private var keyFingerprint: Data?
    private var identity = Identity(name: "iPad", deviceId: UUID().uuidString, displaySize: nil)
    private var pending: [UUID: PeerConnection] = [:]
    private var active: PeerConnection?
    private var wantsListening = false
    private var restartWork: DispatchWorkItem?
    private var restartAttempt = 0
    private var activeAcceptsInput = false
    private var activeWantsStats = false
    private var inputOutbox = InputOutbox()
    private var reportedVideoSize: CGSize?

    /// `events` is called on the main queue.
    init(port: UInt16 = defaultPort, advertise: Bool = true, renderer: AVSampleBufferVideoRenderer,
         events: @escaping (ServerEvent) -> Void) {
        self.port = port
        self.advertise = advertise
        self.advertiseRequested = advertise
        self.video = VideoPipeline(renderer: renderer)
        self.events = events
    }

    /// Starts (or keeps) listening. A different key ends any session authenticated with the old one.
    func start(pairingKey key: Data, identity: Identity) {
        let fingerprint = Data(SHA256.hash(data: key))
        let newKey = SymmetricKey(data: key)
        queue.async { [self] in
            if fingerprint != keyFingerprint {
                closeAllConnections(.stopped)
                pairingKey = newKey
                keyFingerprint = fingerprint
            }
            self.identity = identity
            wantsListening = true
            advertise = advertiseRequested
            startListener()
        }
    }

    /// Records the viewport size for future hellos. If it changed during a session, that session ends
    /// while the listener keeps running, so the PC reconnects and re-creates its display at the new size.
    func updateDisplaySize(_ size: PixelSize?) {
        queue.async { [self] in
            guard identity.displaySize != size else { return }
            identity.displaySize = size
            if let active {
                Self.log.info("Viewport is now \(String(describing: size), privacy: .public); ending session so the PC resizes")
                active.close(.displayResized)
            }
        }
    }

    /// Stops listening and closes every connection (app backgrounded, paused or unpaired).
    func stop() {
        queue.async { [self] in
            wantsListening = false
            restartWork?.cancel()
            restartWork = nil
            listener?.cancel()
            listener = nil
            closeAllConnections(.stopped)
            pairingKey = nil
            keyFingerprint = nil
            emit(.listener(.stopped))
        }
    }

    /// Queues one input event for the current session. Dropped unless that host's hello opted in to input.
    /// Callable from any thread; sealing and sending stay on the session queue.
    func sendInput(_ event: InputEvent) {
        queue.async { [self] in
            guard active != nil, activeAcceptsInput else { return }
            inputOutbox.append(event)
            drainInput()
        }
    }

    // MARK: Listener

    private func startListener() {
        guard wantsListening, listener == nil else { return }
        restartWork?.cancel()
        restartWork = nil

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }

        let newListener: NWListener
        do {
            newListener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            emit(.listener(.failed(Self.describe(error, port: port))))
            scheduleRestart()
            return
        }
        if advertise {
            newListener.service = NWListener.Service(type: Self.serviceType)
        }
        newListener.stateUpdateHandler = { [weak self, weak newListener] state in
            guard let self, let newListener else { return }
            self.listener(newListener, changedTo: state)
        }
        newListener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener = newListener
        emit(.listener(.starting))
        newListener.start(queue: queue)
    }

    private func listener(_ changed: NWListener, changedTo state: NWListener.State) {
        guard changed === listener else { return }
        switch state {
        case .ready:
            restartAttempt = 0
            Self.log.info("Listening on port \(self.port, privacy: .public), Bonjour \(self.advertise, privacy: .public)")
            emit(.listener(.listening(advertising: advertise)))
        case .failed(let error), .waiting(let error):
            changed.cancel()
            listener = nil
            if case .dns = error, advertise {
                // Bonjour refused (usually Local Network access is off). Keep USB working without it.
                Self.log.error("Bonjour unavailable: \(String(describing: error), privacy: .public)")
                advertise = false
                startListener()
                return
            }
            Self.log.error("Listener failed: \(String(describing: error), privacy: .public)")
            emit(.listener(.failed(Self.describe(error, port: port))))
            scheduleRestart()
        default:
            break
        }
    }

    private func scheduleRestart() {
        guard wantsListening else { return }
        let delay = min(pow(2, Double(restartAttempt)), 30)
        restartAttempt += 1
        let work = DispatchWorkItem { [weak self] in self?.startListener() }
        restartWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        guard let key = pairingKey, pending.count < Self.maximumPendingConnections else {
            connection.cancel()
            return
        }
        let peer = PeerConnection(connection: connection, queue: queue, pairingKey: key)
        pending[peer.id] = peer
        peer.onAuthenticated = { [weak self] in self?.promote($0) }
        peer.onRecord = { [weak self] in self?.handleRecord(from: $0, type: $1, payload: $2) }
        peer.onClose = { [weak self] in self?.peerClosed($0, reason: $1) }
        peer.start()
    }

    /// Only an authenticated connection can replace the current session.
    private func promote(_ peer: PeerConnection) {
        pending[peer.id] = nil
        active?.close(.replaced)
        active = peer
        resetSessionState()
        peer.onSendCompleted = { [weak self] in if $0 === self?.active { self?.drainInput() } }
        Self.log.info("Session started from \(peer.endpointDescription, privacy: .public)")
        emit(.sessionStarted)
        peer.send(.hello, identity.hello.encoded())
    }

    private func peerClosed(_ peer: PeerConnection, reason: PeerConnection.CloseReason) {
        pending[peer.id] = nil
        if peer === active {
            active = nil
            resetSessionState()
            Self.log.info("Session ended: \(String(describing: reason), privacy: .public)")
            emit(.sessionEnded(reason))
        } else if reason == .authenticationFailed {
            Self.log.notice("Rejected a connection with a different pairing key")
            emit(.authenticationFailed)
        }
    }

    private func closeAllConnections(_ reason: PeerConnection.CloseReason) {
        let waiting = Array(pending.values)
        pending.removeAll()
        waiting.forEach { $0.close(reason) }
        active?.close(reason)
    }

    private func handleRecord(from peer: PeerConnection, type: UInt8, payload: Data) {
        guard peer === active else { return }
        switch RecordType(rawValue: type) {
        case .hello:
            if let hello = WindowsHello.decode(payload) {
                activeAcceptsInput = hello.acceptsInput
                activeWantsStats = hello.wantsReceiverStats
                if !activeAcceptsInput { inputOutbox.removeAll() }
                emit(.hello(hello))
            }
        case .video:
            if video.consume(payload) { emit(.firstFrame) }
            if let size = video.presentationSize, size != reportedVideoSize {
                reportedVideoSize = size
                emit(.videoSize(size))
            }
        case .identify:
            if let request = IdentifyRequest.decode(payload) { emit(.identify(request)) }
        case .heartbeat:
            guard payload.count <= Self.maximumHeartbeatPayload else {
                peer.close(.protocolViolation("heartbeat too large"))
                return
            }
            if activeWantsStats {
                peer.send(.heartbeat, ReceiverStats(enqueuedFrames: video.enqueuedFrames,
                                                    droppedFrames: video.droppedFrames).encoded())
            } else {
                peer.send(.heartbeat, payload)
            }
        case .error:
            if let message = RemoteErrorMessage.displayText(from: payload) { emit(.remoteError(message)) }
        case .input, .none:
            break  // Input only flows iPad → Windows; unknown types from a newer host are ignored.
        }
    }

    /// Sends queued input while the connection has room; the rest waits (and coalesces) in the outbox.
    private func drainInput() {
        guard let active, activeAcceptsInput else {
            inputOutbox.removeAll()
            return
        }
        while active.sendsInFlight < Self.maximumInputSendsInFlight, let event = inputOutbox.popFirst() {
            guard let payload = event.encoded() else { continue }
            active.send(.input, payload)
        }
    }

    private func resetSessionState() {
        video.reset()
        activeAcceptsInput = false
        activeWantsStats = false
        inputOutbox.removeAll()
        reportedVideoSize = nil
    }

    private func emit(_ event: ServerEvent) {
        let events = self.events
        DispatchQueue.main.async { events(event) }
    }

    private static func describe(_ error: Error, port: UInt16) -> String {
        if let error = error as? NWError, case .posix(let code) = error, code == .EADDRINUSE {
            return "Port \(port) is already in use on this iPad."
        }
        return "Couldn't listen for connections (\(error))."
    }
}
