import CryptoKit
import XCTest
@testable import OpenDisplay

/// Published primitive vectors, plus protocol vectors computed independently by
/// work/ipad-vectors/vectors.py (Python stdlib) and vectors.swift (raw CryptoKit).
final class CryptoVectorTests: XCTestCase {
    private let key = SymmetricKey(data: Vectors.pairingKey)

    func testHMACSHA256MatchesRFC4231Case2() {
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data("what do ya want for nothing?".utf8), using: SymmetricKey(data: Data("Jefe".utf8)))
        XCTAssertEqual(hexString(Data(mac)), "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
    }

    func testHKDFSHA256MatchesRFC5869Case1() {
        let okm = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(repeating: 0x0B, count: 22)),
            salt: bytes(0x00..<0x0D), info: bytes(0xF0..<0xFA), outputByteCount: 42)
        XCTAssertEqual(okm.withUnsafeBytes { hexString(Array($0)) },
                       "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865")
    }

    /// McGrew & Viega GCM test cases 13 and 14 (AES-256, zero key, zero 96-bit IV).
    func testAES256GCMMatchesPublishedVectors() throws {
        let zeroKey = SymmetricKey(data: Data(count: 32))
        let zeroNonce = try AES.GCM.Nonce(data: Data(count: 12))

        let empty = try AES.GCM.seal(Data(), using: zeroKey, nonce: zeroNonce)
        XCTAssertEqual(hexString(empty.tag), "530f8afbc74536b9a963b4f1c4cb738b")

        let block = try AES.GCM.seal(Data(count: 16), using: zeroKey, nonce: zeroNonce)
        XCTAssertEqual(hexString(block.ciphertext), "cea7403d4d606b6e074ec5d3baf39d18")
        XCTAssertEqual(hexString(block.tag), "d0d1c8a799996bf0265b98b5d48ab919")
    }

    func testRecordNonceIsFourZeroBytesThenBigEndianSequence() {
        XCTAssertEqual(RecordFormat.nonce(for: 0).withUnsafeBytes { Data($0) }, Data(count: 12))
        XCTAssertEqual(RecordFormat.nonce(for: 0x0102_0304_0506_0708).withUnsafeBytes { hexString(Array($0)) },
                       "000000000102030405060708")
    }

    func testServerHelloMatchesIndependentVector() {
        let hello = Handshake.serverHello(key: key, c: Vectors.c, s: Vectors.s)
        XCTAssertEqual(hello.count, Handshake.serverHelloLength)
        XCTAssertEqual(hexString(hello),
                       "4f504131" + "404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f"
                       + "7bd56124f0c755608ad22d3770f241d01be3c39f2e0d11c8df24b3165306e616")
    }

    func testClientProofMatchesIndependentVector() {
        let proof = hexData("80c7a53b2dfb254d462a2d8f2d0aeb69f8fdd9180ea0876bcc14a93c242e0a9b")
        XCTAssertEqual(Handshake.clientMAC(key: key, c: Vectors.c, s: Vectors.s), proof)
        XCTAssertTrue(Handshake.verifyClientProof(proof, key: key, c: Vectors.c, s: Vectors.s))
    }

    func testSessionKeysMatchIndependentVectors() {
        let keys = Handshake.sessionKeys(key: key, c: Vectors.c, s: Vectors.s)
        XCTAssertEqual(keys.receive.withUnsafeBytes { hexString(Array($0)) },
                       "2f5e4e0a9459deef95a7e703080d1594fcfa2ed872277d55b8b7759e279ffc9c")
        XCTAssertEqual(keys.send.withUnsafeBytes { hexString(Array($0)) },
                       "aceda95b4826948f10276cc88c32fa78a4c056567d2b900f38f71d5a0d696c34")
    }

    func testClientHelloParsing() {
        XCTAssertEqual(Handshake.clientNonce(fromHello: Data("OPD1".utf8) + Vectors.c), Vectors.c)
        XCTAssertNil(Handshake.clientNonce(fromHello: Data("OPX1".utf8) + Vectors.c))
        XCTAssertNil(Handshake.clientNonce(fromHello: Data("OPD1".utf8) + Vectors.c.dropLast()))
        XCTAssertNil(Handshake.clientNonce(fromHello: Data("GET / HTTP/1.1\r\nHost: ipad\r\n\r\n".utf8)))
        // A slice with a non-zero start index must parse the same as a fresh buffer.
        let padded = Data([0xAA]) + Data("OPD1".utf8) + Vectors.c
        XCTAssertEqual(Handshake.clientNonce(fromHello: padded.dropFirst()), Vectors.c)
    }

    func testClientProofRejectsTamperingAndWrongLength() {
        var proof = Handshake.clientMAC(key: key, c: Vectors.c, s: Vectors.s)
        proof[proof.startIndex] ^= 0x01
        XCTAssertFalse(Handshake.verifyClientProof(proof, key: key, c: Vectors.c, s: Vectors.s))
        XCTAssertFalse(Handshake.verifyClientProof(Data(proof.prefix(31)), key: key, c: Vectors.c, s: Vectors.s))
        // The server's own MAC must never be accepted as the client's proof.
        let serverMAC = Handshake.serverMAC(key: key, c: Vectors.c, s: Vectors.s)
        XCTAssertFalse(Handshake.verifyClientProof(serverMAC, key: key, c: Vectors.c, s: Vectors.s))
        let otherKey = SymmetricKey(data: Data(repeating: 0x5A, count: 32))
        XCTAssertFalse(Handshake.verifyClientProof(Handshake.clientMAC(key: otherKey, c: Vectors.c, s: Vectors.s),
                                                   key: key, c: Vectors.c, s: Vectors.s))
    }

    func testServerNoncesAreFreshAndFullLength() {
        let nonces = (0..<64).map { _ in Handshake.randomNonce() }
        XCTAssertTrue(nonces.allSatisfy { $0.count == Handshake.nonceLength })
        XCTAssertEqual(Set(nonces).count, nonces.count)
    }
}
