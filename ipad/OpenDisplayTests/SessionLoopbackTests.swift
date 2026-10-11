import AVFoundation
import CryptoKit
import Network
import XCTest
@testable import OpenDisplay

/// Drives the real DisplayServer over loopback TCP with an independent test client.
final class SessionLoopbackTests: XCTestCase {
    private var server: DisplayServer!
    private var port: UInt16 = 0
    private var log: [String] = []
    private let displayLayer = AVSampleBufferDisplayLayer()

    override func setUp() {
        super.setUp()
        port = UInt16.random(in: 50_000...59_000)
        log = []
        server = DisplayServer(port: port, advertise: false, renderer: displayLayer.sampleBufferRenderer) { [weak self] event in
            self?.log.append(Self.name(of: event))
        }
        server.start(pairingKey: Vectors.pairingKey, identity: .init(name: "Test iPad", deviceId: "TEST-DEVICE"))
        XCTAssertTrue(waitUntil { self.log.contains("listening") }, "listener never became ready: \(log)")
    }

    override func tearDown() {
        server.stop()
        server = nil
        super.tearDown()
    }

    func testAuthenticatedSessionSendsHelloAndEchoesHeartbeats() throws {
        let client = TestClient(port: port)
        XCTAssertTrue(client.authenticate(key: Vectors.pairingKey))

        let hello = try XCTUnwrap(client.readRecord())
        XCTAssertEqual(hello.type, RecordType.hello.rawValue)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: hello.payload) as? [String: Any])
        XCTAssertEqual(object["name"] as? String, "Test iPad")
        XCTAssertEqual(object["deviceId"] as? String, "TEST-DEVICE")
        XCTAssertEqual(object["ready"] as? Bool, true)

        for beat in 0..<3 {
            let payload = Data([0xA0, UInt8(beat)])
            try client.sendRecord(.heartbeat, payload)
            let echo = try XCTUnwrap(client.readRecord())
            XCTAssertEqual(echo.type, RecordType.heartbeat.rawValue)
            XCTAssertEqual(echo.payload, payload)
        }
        XCTAssertTrue(waitUntil { self.log.contains("sessionStarted") })
    }

    func testHelloAndIdentifyReachTheApp() throws {
        let client = TestClient(port: port)
        XCTAssertTrue(client.authenticate(key: Vectors.pairingKey))
        try client.sendRecord(.hello, Data(#"{"name":"PC","width":1600,"height":1000,"fps":30,"transport":"USB","ipadEdge":"left"}"#.utf8))
        try client.sendRecord(.identify, Data(#"{"edge":"right","seconds":3}"#.utf8))
        XCTAssertTrue(waitUntil { self.log.contains("hello:left") && self.log.contains("identify:right") }, "\(log)")
    }

    func testFailedProofDoesNotInterruptTheCurrentSession() throws {
        let current = TestClient(port: port)
        XCTAssertTrue(current.authenticate(key: Vectors.pairingKey))
        _ = try XCTUnwrap(current.readRecord())

        let intruder = TestClient(port: port)
        XCTAssertTrue(intruder.authenticate(key: Vectors.pairingKey, corruptProof: true))
        XCTAssertTrue(intruder.waitForClose(), "a bad proof must be rejected")

        let wrongKey = TestClient(port: port)
        XCTAssertFalse(wrongKey.authenticate(key: Data(repeating: 0x5A, count: 32)), "server MAC must not verify under another key")
        wrongKey.cancel()

        try current.sendRecord(.heartbeat, Data([1]))
        XCTAssertEqual(try current.readRecord()?.payload, Data([1]))
        XCTAssertTrue(waitUntil { self.log.filter { $0 == "authenticationFailed" }.count == 2 }, "\(log)")
        XCTAssertFalse(log.contains { $0.hasPrefix("sessionEnded") }, "\(log)")
    }

    func testNonOpenDisplayClientIsClosed() {
        let client = TestClient(port: port)
        client.send(Data("GET / HTTP/1.1\r\nHost: ipad.local\r\n\r\n".utf8))
        XCTAssertTrue(client.waitForClose())
        XCTAssertFalse(log.contains("sessionStarted"))
    }

    func testNewAuthenticatedConnectionReplacesTheOldSession() throws {
        let first = TestClient(port: port)
        XCTAssertTrue(first.authenticate(key: Vectors.pairingKey))
        _ = try XCTUnwrap(first.readRecord())

        let second = TestClient(port: port)
        XCTAssertTrue(second.authenticate(key: Vectors.pairingKey))
        _ = try XCTUnwrap(second.readRecord())

        XCTAssertTrue(first.waitForClose())
        try second.sendRecord(.heartbeat, Data([2]))
        XCTAssertEqual(try second.readRecord()?.payload, Data([2]))
        XCTAssertTrue(waitUntil { self.log.contains("sessionEnded:replaced") }, "\(log)")
    }

    func testSilentConnectionIsClosedAtTheHandshakeDeadline() {
        let started = Date()
        let client = TestClient(port: port)
        XCTAssertTrue(client.waitForClose(timeout: Handshake.deadline + 3))
        XCTAssertGreaterThan(Date().timeIntervalSince(started), Handshake.deadline - 0.5)
    }

    func testOutOfRangeRecordLengthClosesTheSession() throws {
        let client = TestClient(port: port)
        XCTAssertTrue(client.authenticate(key: Vectors.pairingKey))
        _ = try XCTUnwrap(client.readRecord())
        client.send(Data([0xFF, 0xFF, 0xFF, 0xFF]))
        XCTAssertTrue(client.waitForClose())
        XCTAssertTrue(waitUntil { self.log.contains { $0.hasPrefix("sessionEnded:protocolViolation") } }, "\(log)")
    }

    func testRealVideoInArbitraryRecordsReachesTheDecoder() throws {
        let encoded = try EncodedTestStream.make(width: 320, height: 240, frameCount: 6)
        let client = TestClient(port: port)
        XCTAssertTrue(client.authenticate(key: Vectors.pairingKey))
        _ = try XCTUnwrap(client.readRecord())

        let stream = encoded.annexB + Data([0, 0, 0, 1, 0x09, 0xF0])
        var rng = SeededGenerator(seed: 7)
        var offset = 0
        while offset < stream.count {
            let end = min(stream.count, offset + Int.random(in: 1...700, using: &rng))
            try client.sendRecord(.video, stream.subdata(in: offset..<end))
            offset = end
        }
        XCTAssertTrue(waitUntil { self.log.contains("firstFrame") }, "\(log)")
    }

    func testViewportChangeEndsSessionAndReconnectGetsNewSize() throws {
        server.updateDisplaySize(PixelSize(width: 2420, height: 1668))
        let first = TestClient(port: port)
        XCTAssertTrue(first.authenticate(key: Vectors.pairingKey))
        let landscape = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(first.readRecord()).payload) as? [String: Any])
        XCTAssertEqual(landscape["displayWidth"] as? Int, 2420)
        XCTAssertEqual(landscape["displayHeight"] as? Int, 1668)

        server.updateDisplaySize(PixelSize(width: 1668, height: 2420))  // rotated to portrait
        XCTAssertTrue(first.waitForClose())
        XCTAssertTrue(waitUntil { self.log.contains("sessionEnded:displayResized") }, "\(log)")

        let second = TestClient(port: port)  // the listener stayed up
        XCTAssertTrue(second.authenticate(key: Vectors.pairingKey))
        let portrait = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(second.readRecord()).payload) as? [String: Any])
        XCTAssertEqual(portrait["displayWidth"] as? Int, 1668)
        XCTAssertEqual(portrait["displayHeight"] as? Int, 2420)

        server.updateDisplaySize(PixelSize(width: 1668, height: 2420))  // unchanged: session must survive
        try second.sendRecord(.heartbeat, Data([3]))
        XCTAssertEqual(try second.readRecord()?.payload, Data([3]))
    }

    func testStopClosesTheSession() throws {
        let client = TestClient(port: port)
        XCTAssertTrue(client.authenticate(key: Vectors.pairingKey))
        _ = try XCTUnwrap(client.readRecord())
        server.stop()
        XCTAssertTrue(client.waitForClose())
        XCTAssertTrue(waitUntil { self.log.contains("sessionEnded:stopped") && self.log.contains("stopped") }, "\(log)")
    }

    // MARK: Input and receiver stats

    private func connectHost(hello: String) throws -> TestClient {
        let client = TestClient(port: port)
        XCTAssertTrue(client.authenticate(key: Vectors.pairingKey))
        _ = try XCTUnwrap(client.readRecord())
        try client.sendRecord(.hello, Data(hello.utf8))
        XCTAssertTrue(waitUntil { self.log.contains { $0.hasPrefix("hello:") } }, "\(log)")
        return client
    }

    func testInputReachesAHostThatOptedIn() throws {
        let client = try connectHost(hello: #"{"name":"PC","inputVersion":1}"#)
        server.sendInput(.pointer(x: 0.5, y: 0.25, phase: .down, button: .left))
        server.sendInput(.key(code: HIDUsage.a, down: true))
        server.sendInput(.releaseAll)

        var objects: [[String: Any]] = []
        for _ in 0..<3 {
            let record = try XCTUnwrap(client.readRecord())
            XCTAssertEqual(record.type, RecordType.input.rawValue)
            XCTAssertLessThanOrEqual(record.payload.count, InputEvent.maximumPayload)
            objects.append(try XCTUnwrap(JSONSerialization.jsonObject(with: record.payload) as? [String: Any]))
        }
        XCTAssertEqual(objects.map { $0["kind"] as? String }, ["pointer", "key", "releaseAll"])
        XCTAssertEqual(objects[0]["x"] as? Double, 0.5)
        XCTAssertEqual(objects[0]["y"] as? Double, 0.25)
        XCTAssertEqual(objects[0]["phase"] as? String, "down")
        XCTAssertEqual(objects[1]["code"] as? Int, 4)
        XCTAssertEqual(objects[1]["down"] as? Bool, true)
    }

    func testOldHostGetsNoInputAndAnOpaqueHeartbeatEcho() throws {
        let client = try connectHost(hello: #"{"name":"PC","width":1600,"height":1000}"#)
        server.sendInput(.key(code: HIDUsage.a, down: true))
        server.sendInput(.pointer(x: 0.5, y: 0.5, phase: .move, button: .left))
        try client.sendRecord(.heartbeat, Data([0xBE, 0xEF]))
        let reply = try XCTUnwrap(client.readRecord())
        XCTAssertEqual(reply.type, RecordType.heartbeat.rawValue, "input must not reach a host without inputVersion")
        XCTAssertEqual(reply.payload, Data([0xBE, 0xEF]))
    }

    func testHeartbeatCarriesReceiverStatsWhenRequested() throws {
        let encoded = try EncodedTestStream.make(width: 320, height: 240, frameCount: 4)
        let client = try connectHost(hello: #"{"name":"PC","receiverStatsVersion":1}"#)
        try client.sendRecord(.video, encoded.annexB + Data([0, 0, 0, 1, 0x09, 0xF0]))
        XCTAssertTrue(waitUntil { self.log.contains("firstFrame") }, "\(log)")
        XCTAssertTrue(waitUntil { self.log.contains("videoSize:320x240") }, "\(log)")

        try client.sendRecord(.heartbeat, Data([1, 2, 3]))
        let reply = try XCTUnwrap(client.readRecord())
        XCTAssertEqual(reply.type, RecordType.heartbeat.rawValue)
        let stats = try XCTUnwrap(JSONSerialization.jsonObject(with: reply.payload) as? [String: Int])
        XCTAssertEqual(Set(stats.keys), ["enqueuedFrames", "droppedFrames"])
        XCTAssertLessThanOrEqual((stats["enqueuedFrames"] ?? 0) + (stats["droppedFrames"] ?? 0), 4)
        XCTAssertGreaterThan(stats["enqueuedFrames"] ?? 0, 0)
    }

    func testMoveFloodNeverDropsReleasesOrStallsHeartbeats() throws {
        let client = try connectHost(hello: #"{"name":"PC","inputVersion":1}"#)
        for i in 0..<5000 {
            server.sendInput(.pointer(x: Double(i % 1000) / 1000, y: 0.5, phase: .move, button: .left))
        }
        server.sendInput(.pointer(x: 0.9, y: 0.5, phase: .up, button: .left))
        server.sendInput(.key(code: HIDUsage.leftShift, down: false))
        try client.sendRecord(.heartbeat, Data([7]))

        var kinds: [String] = []
        var sawHeartbeat = false
        while !(kinds.contains("key") && sawHeartbeat) {
            let record = try XCTUnwrap(client.readRecord(), "session stalled after \(kinds.count) input records")
            if record.type == RecordType.heartbeat.rawValue {
                XCTAssertEqual(record.payload, Data([7]))
                sawHeartbeat = true
                continue
            }
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: record.payload) as? [String: Any])
            kinds.append(object["phase"] as? String ?? object["kind"] as? String ?? "?")
        }
        XCTAssertLessThanOrEqual(kinds.count, 5002)
        XCTAssertEqual(Array(kinds.suffix(2)), ["up", "key"], "releases arrive last and in order")
        XCTAssertFalse(log.contains { $0.hasPrefix("sessionEnded") }, "\(log)")
    }

    // MARK: Helpers

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    private static func name(of event: ServerEvent) -> String {
        switch event {
        case .listener(.listening): "listening"
        case .listener(.stopped): "stopped"
        case .listener(let status): "listener:\(status)"
        case .sessionStarted: "sessionStarted"
        case .hello(let hello): "hello:\(hello.ipadEdge ?? "none")"
        case .identify(let request): "identify:\(request.edge)"
        case .firstFrame: "firstFrame"
        case .videoSize(let size): "videoSize:\(Int(size.width))x\(Int(size.height))"
        case .remoteError(let message): "remoteError:\(message)"
        case .sessionEnded(let reason): "sessionEnded:\(reason)"
        case .authenticationFailed: "authenticationFailed"
        }
    }
}

/// A minimal Windows-side client: blocking reads on its own queue, with timeouts.
private final class TestClient {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "OpenDisplayTests.client")
    private var sealer: RecordSealer?
    private var opener: RecordOpener?

    init(port: UInt16) {
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection.start(queue: queue)
    }

    deinit { connection.cancel() }

    func cancel() { connection.cancel() }

    func send(_ data: Data) {
        connection.send(content: data, completion: .idempotent)
    }

    func receive(exactly count: Int, timeout: TimeInterval = 5) -> Data? {
        let done = DispatchSemaphore(value: 0)
        var result: Data?
        connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, _ in
            result = data
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success, let data = result, data.count == count else { return nil }
        return Data(data)
    }

    /// True once the server closes the connection.
    func waitForClose(timeout: TimeInterval = 5) -> Bool {
        let deadline = DispatchTime.now() + timeout
        while true {
            let done = DispatchSemaphore(value: 0)
            var closed = false
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                closed = error != nil || (isComplete && (data?.isEmpty ?? true))
                done.signal()
            }
            guard done.wait(timeout: deadline) == .success else { return false }
            if closed { return true }
        }
    }

    /// Runs the Windows side of the handshake. Returns false if the server's MAC doesn't verify.
    func authenticate(key: Data, corruptProof: Bool = false) -> Bool {
        let pairingKey = SymmetricKey(data: key)
        let c = Handshake.randomNonce()
        send(Handshake.clientMagic + c)

        guard let hello = receive(exactly: Handshake.serverHelloLength), hello.prefix(4) == Handshake.serverMagic else { return false }
        let s = hello.subdata(in: 4..<36)
        guard hello.subdata(in: 36..<68) == Handshake.serverMAC(key: pairingKey, c: c, s: s) else { return false }

        var proof = Handshake.clientMAC(key: pairingKey, c: c, s: s)
        if corruptProof { proof[proof.startIndex] ^= 0x01 }
        send(proof)

        let keys = Handshake.sessionKeys(key: pairingKey, c: c, s: s)
        sealer = RecordSealer(key: keys.receive)  // Windows → iPad
        opener = RecordOpener(key: keys.send)     // iPad → Windows
        return true
    }

    func sendRecord(_ type: RecordType, _ payload: Data) throws {
        send(try sealer!.seal(type: type.rawValue, payload: payload))
    }

    func readRecord(timeout: TimeInterval = 5) throws -> (type: UInt8, payload: Data)? {
        guard let prefix = receive(exactly: 4, timeout: timeout),
              let length = RecordFormat.bodyLength(fromPrefix: prefix),
              let body = receive(exactly: length, timeout: timeout)
        else { return nil }
        return try opener!.open(body: body)
    }
}
