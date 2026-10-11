import CryptoKit
import Foundation
import Network

/// One inbound TCP connection: the handshake, then encrypted records.
/// Everything runs on the server's serial queue, which also makes it the single writer.
final class PeerConnection {
    enum CloseReason: Equatable {
        case remoteClosed
        /// The peer spoke OpenDisplay but the pairing keys don't match.
        case authenticationFailed
        case notOpenDisplay
        case timedOut
        case protocolViolation(String)
        case networkError(String)
        case replaced
        case stopped
        /// The viewport changed size; the PC reconnects and receives the new size in the next hello.
        case displayResized
    }

    static let livenessTimeout: TimeInterval = 8
    static let maximumSendsInFlight = 32

    let id = UUID()
    private(set) var isAuthenticated = false

    var onAuthenticated: ((PeerConnection) -> Void)?
    var onRecord: ((PeerConnection, UInt8, Data) -> Void)?
    var onClose: ((PeerConnection, CloseReason) -> Void)?
    /// A queued record was handed to the network stack, so there is room for another.
    var onSendCompleted: ((PeerConnection) -> Void)?

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let pairingKey: SymmetricKey
    private var sealer: RecordSealer?
    private var opener: RecordOpener?
    private var handshakeTimer: DispatchWorkItem?
    private var livenessTimer: DispatchSourceTimer?
    private var lastReceive = DispatchTime.now()
    private(set) var sendsInFlight = 0
    private var receivedClientHello = false
    private var closed = false

    init(connection: NWConnection, queue: DispatchQueue, pairingKey: SymmetricKey) {
        self.connection = connection
        self.queue = queue
        self.pairingKey = pairingKey
    }

    var endpointDescription: String { "\(connection.endpoint)" }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error): self?.close(.networkError("\(error)"))
            case .cancelled: self?.close(.remoteClosed)
            default: break
            }
        }

        let deadline = DispatchWorkItem { [weak self] in self?.close(.timedOut) }
        handshakeTimer = deadline
        queue.asyncAfter(deadline: .now() + Handshake.deadline, execute: deadline)

        connection.start(queue: queue)
        receive(exactly: Handshake.clientHelloLength) { [weak self] in self?.handleClientHello($0) }
    }

    /// Seals and queues one record. Closes instead of letting a stalled peer grow an unbounded queue.
    func send(_ type: RecordType, _ payload: Data) {
        guard !closed, sealer != nil else { return }
        guard sendsInFlight < Self.maximumSendsInFlight else {
            close(.protocolViolation("send queue stalled"))
            return
        }
        do {
            sendRaw(try sealer!.seal(type: type.rawValue, payload: payload))
        } catch {
            close(.protocolViolation("could not seal record"))
        }
    }

    func close(_ reason: CloseReason) {
        guard !closed else { return }
        closed = true
        handshakeTimer?.cancel()
        handshakeTimer = nil
        livenessTimer?.cancel()
        livenessTimer = nil
        connection.stateUpdateHandler = nil
        connection.cancel()

        let handler = onClose
        onClose = nil
        onRecord = nil
        onAuthenticated = nil
        onSendCompleted = nil
        handler?(self, reason)
    }

    // MARK: Handshake

    private func handleClientHello(_ hello: Data) {
        guard let c = Handshake.clientNonce(fromHello: hello) else {
            close(.notOpenDisplay)
            return
        }
        receivedClientHello = true
        let s = Handshake.randomNonce()
        sendRaw(Handshake.serverHello(key: pairingKey, c: c, s: s))
        receive(exactly: Handshake.clientProofLength) { [weak self] in self?.handleClientProof($0, c: c, s: s) }
    }

    private func handleClientProof(_ proof: Data, c: Data, s: Data) {
        guard Handshake.verifyClientProof(proof, key: pairingKey, c: c, s: s) else {
            close(.authenticationFailed)
            return
        }
        handshakeTimer?.cancel()
        handshakeTimer = nil

        let keys = Handshake.sessionKeys(key: pairingKey, c: c, s: s)
        sealer = RecordSealer(key: keys.send)
        opener = RecordOpener(key: keys.receive)
        isAuthenticated = true
        startLivenessTimer()

        onAuthenticated?(self)
        if !closed { readRecord() }
    }

    // MARK: Records

    private func readRecord() {
        receive(exactly: RecordFormat.lengthPrefixSize) { [weak self] prefix in
            guard let self else { return }
            // L is validated before the body is requested, so a hostile length never allocates.
            guard let length = RecordFormat.bodyLength(fromPrefix: prefix) else {
                self.close(.protocolViolation("record length out of range"))
                return
            }
            self.receive(exactly: length) { [weak self] body in
                guard let self else { return }
                let record: (type: UInt8, payload: Data)
                do {
                    record = try self.opener!.open(body: body)
                } catch {
                    self.close(.protocolViolation("record rejected"))
                    return
                }
                self.onRecord?(self, record.type, record.payload)
                if !self.closed { self.readRecord() }
            }
        }
    }

    // MARK: I/O

    private func receive(exactly count: Int, then handler: @escaping (Data) -> Void) {
        connection.receive(minimumIncompleteLength: count, maximumLength: count) { [weak self] data, _, _, error in
            guard let self, !self.closed else { return }
            if let data, data.count == count {
                self.lastReceive = .now()
                handler(data)
            } else if let error {
                self.close(.networkError("\(error)"))
            } else {
                // The peer hung up. Mid-handshake after our proof, that means it rejected our key.
                self.close(self.receivedClientHello && !self.isAuthenticated ? .authenticationFailed : .remoteClosed)
            }
        }
    }

    private func sendRaw(_ data: Data) {
        sendsInFlight += 1
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.sendsInFlight -= 1
            if let error {
                self.close(.networkError("\(error)"))
            } else {
                self.onSendCompleted?(self)
            }
        })
    }

    private func startLivenessTimer() {
        lastReceive = .now()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let idle = Double(DispatchTime.now().uptimeNanoseconds - self.lastReceive.uptimeNanoseconds) / 1_000_000_000
            if idle > Self.livenessTimeout { self.close(.timedOut) }
        }
        timer.resume()
        livenessTimer = timer
    }
}
