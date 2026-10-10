import CryptoKit
import Foundation

enum RecordType: UInt8 {
    case hello = 1
    case video = 2
    case identify = 3
    case heartbeat = 4
    case input = 5   // Reserved; v1 has no remote input.
    case error = 6
}

/// `uint32 L ‖ uint64 sequence ‖ ciphertext ‖ tag`, big-endian, AES-256-GCM.
/// L covers sequence + ciphertext + tag. Plaintext is `type ‖ payload`.
enum RecordFormat {
    static let lengthPrefixSize = 4
    static let sequenceSize = 8
    static let tagSize = 16
    static let minimumLength = 25            // 8 + 1-byte type + 16
    static let maximumLength = 8_388_633     // 8 + 1 + 8 MiB + 16
    static let maximumPayload = maximumLength - minimumLength

    /// Validates a length prefix before any body allocation. Returns L, or nil if it is out of range.
    static func bodyLength(fromPrefix prefix: Data) -> Int? {
        let prefix = Data(prefix)
        guard prefix.count == lengthPrefixSize else { return nil }
        let length = Int(readUInt32(prefix))
        return (minimumLength...maximumLength).contains(length) ? length : nil
    }

    static func sequenceBytes(_ sequence: UInt64) -> Data {
        withUnsafeBytes(of: sequence.bigEndian) { Data($0) }
    }

    /// 4 zero bytes ‖ 8-byte big-endian sequence.
    static func nonce(for sequence: UInt64) -> AES.GCM.Nonce {
        // 12 bytes is always a valid GCM nonce length.
        try! AES.GCM.Nonce(data: Data(count: 4) + sequenceBytes(sequence))
    }

    static func readUInt32(_ data: Data) -> UInt32 {
        data.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    static func readUInt64(_ data: Data) -> UInt64 {
        data.prefix(8).reduce(0) { $0 << 8 | UInt64($1) }
    }
}

enum RecordError: Error, Equatable {
    case lengthOutOfRange
    case payloadTooLarge
    case unexpectedSequence(expected: UInt64, received: UInt64)
    case authenticationFailed
    case emptyPlaintext
    case sequenceExhausted
}

/// Seals outgoing records for one direction. Not thread-safe: use from the single writer only.
struct RecordSealer {
    private let key: SymmetricKey
    private(set) var nextSequence: UInt64 = 0
    private var exhausted = false

    init(key: SymmetricKey) { self.key = key }

    /// Returns the complete record, including the length prefix.
    mutating func seal(type: UInt8, payload: Data) throws -> Data {
        guard payload.count <= RecordFormat.maximumPayload else { throw RecordError.payloadTooLarge }
        guard !exhausted else { throw RecordError.sequenceExhausted }

        let sequence = nextSequence
        let sequenceBytes = RecordFormat.sequenceBytes(sequence)
        let box = try AES.GCM.seal(Data([type]) + payload, using: key,
                                   nonce: RecordFormat.nonce(for: sequence), authenticating: sequenceBytes)

        if sequence == .max { exhausted = true } else { nextSequence = sequence + 1 }

        let length = UInt32(RecordFormat.sequenceSize + box.ciphertext.count + RecordFormat.tagSize)
        var record = Data(capacity: RecordFormat.lengthPrefixSize + Int(length))
        record.append(contentsOf: withUnsafeBytes(of: length.bigEndian) { Array($0) })
        record.append(sequenceBytes)
        record.append(box.ciphertext)
        record.append(box.tag)
        return record
    }
}

/// Opens incoming records for one direction, enforcing strictly consecutive sequences.
struct RecordOpener {
    private let key: SymmetricKey
    private(set) var expectedSequence: UInt64 = 0

    init(key: SymmetricKey) { self.key = key }

    /// `body` is everything after the length prefix.
    mutating func open(body: Data) throws -> (type: UInt8, payload: Data) {
        let body = Data(body)
        guard (RecordFormat.minimumLength...RecordFormat.maximumLength).contains(body.count) else {
            throw RecordError.lengthOutOfRange
        }

        let sequence = RecordFormat.readUInt64(body)
        guard sequence == expectedSequence else {
            throw RecordError.unexpectedSequence(expected: expectedSequence, received: sequence)
        }

        let sequenceBytes = body.prefix(RecordFormat.sequenceSize)
        let ciphertext = body.subdata(in: RecordFormat.sequenceSize..<(body.count - RecordFormat.tagSize))
        let tag = body.suffix(RecordFormat.tagSize)

        let plaintext: Data
        do {
            let box = try AES.GCM.SealedBox(nonce: RecordFormat.nonce(for: sequence), ciphertext: ciphertext, tag: tag)
            plaintext = try AES.GCM.open(box, using: key, authenticating: sequenceBytes)
        } catch {
            throw RecordError.authenticationFailed
        }

        guard let type = plaintext.first else { throw RecordError.emptyPlaintext }
        expectedSequence &+= 1
        return (type, Data(plaintext.dropFirst()))
    }
}
