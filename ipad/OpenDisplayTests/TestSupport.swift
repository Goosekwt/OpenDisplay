import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import XCTest
@testable import OpenDisplay

func hexString<D: DataProtocol>(_ data: D) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

func hexData(_ hex: String) -> Data {
    var data = Data(capacity: hex.count / 2)
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        data.append(UInt8(hex[index..<next], radix: 16)!)
        index = next
    }
    return data
}

func bytes(_ range: Range<Int>) -> Data {
    Data(range.map { UInt8($0) })
}

/// SplitMix64, so "random" chunkings are reproducible.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Synthetic protocol inputs shared with work/ipad-vectors. Never a real pairing key.
enum Vectors {
    static let pairingKey = bytes(0x00..<0x20)
    static let c = bytes(0x20..<0x40)
    static let s = bytes(0x40..<0x60)
}

/// Real H.264 from VideoToolbox, converted to the Annex B stream Windows sends (AUD first, SPS/PPS at IDRs).
enum EncodedTestStream {
    struct Stream {
        var annexB: Data
        var keyframes: [Bool]
    }

    static func make(width: Int, height: Int, frameCount: Int) throws -> Stream {
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        guard status == noErr, let session = created else { throw XCTSkip("No H.264 encoder available (status \(status)).") }
        defer { VTCompressionSessionInvalidate(session) }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: 5))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)

        let lock = NSLock()
        var samples: [(index: Int, sample: CMSampleBuffer)] = []
        var failures: [OSStatus] = []
        for index in 0..<frameCount {
            let pixels = try pixelBuffer(width: width, height: height, seed: index)
            let encodeStatus = VTCompressionSessionEncodeFrame(
                session, imageBuffer: pixels,
                presentationTimeStamp: CMTime(value: CMTimeValue(index), timescale: 30),
                duration: CMTime(value: 1, timescale: 30),
                frameProperties: nil, infoFlagsOut: nil
            ) { status, _, sample in
                lock.lock()
                defer { lock.unlock() }
                if status == noErr, let sample { samples.append((index, sample)) } else { failures.append(status) }
            }
            guard encodeStatus == noErr else { throw XCTSkip("Encoder rejected a frame (status \(encodeStatus)).") }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)

        lock.lock()
        defer { lock.unlock() }
        XCTAssertEqual(failures, [])

        var stream = Data()
        var keyframes: [Bool] = []
        var shortStartCode = false
        for (_, sample) in samples.sorted(by: { $0.index < $1.index }) {
            let isKey = isKeyframe(sample)
            keyframes.append(isKey)
            stream.append(contentsOf: [0, 0, 0, 1, 0x09, 0xF0])
            if isKey {
                let format = try XCTUnwrap(CMSampleBufferGetFormatDescription(sample))
                var count = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                    parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
                for index in 0..<count {
                    var pointer: UnsafePointer<UInt8>?
                    var size = 0
                    CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                        format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                        parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                    stream.append(contentsOf: [0, 0, 0, 1])
                    stream.append(try XCTUnwrap(pointer), count: size)
                }
            }

            let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
            let length = CMBlockBufferGetDataLength(block)
            var avcc = Data(count: length)
            let copyStatus = avcc.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
            }
            XCTAssertEqual(copyStatus, kCMBlockBufferNoErr)

            var offset = 0
            while offset + 4 <= avcc.count {
                let size = Int(RecordFormat.readUInt32(avcc.subdata(in: offset..<offset + 4)))
                offset += 4
                guard size > 0, offset + size <= avcc.count else { break }
                // Mix 3- and 4-byte start codes, as encoders do.
                stream.append(contentsOf: shortStartCode ? [0, 0, 1] : [0, 0, 0, 1])
                shortStartCode.toggle()
                stream.append(avcc.subdata(in: offset..<offset + size))
                offset += size
            }
        }
        return Stream(annexB: stream, keyframes: keyframes)
    }

    static func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as NSArray?,
              let first = attachments.firstObject as? NSDictionary
        else { return true }
        return !((first[kCMSampleAttachmentKey_NotSync as String] as? Bool) ?? false)
    }

    private static func pixelBuffer(width: Int, height: Int, seed: Int) throws -> CVPixelBuffer {
        var created: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &created)
        let buffer = try XCTUnwrap(created, "CVPixelBufferCreate failed: \(status)")
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let pixel = base + y * bytesPerRow + x * 4
                pixel[0] = UInt8(truncatingIfNeeded: x + seed * 9)
                pixel[1] = UInt8(truncatingIfNeeded: y + seed * 5)
                pixel[2] = UInt8(truncatingIfNeeded: (x ^ y) + seed)
                pixel[3] = 255
            }
        }
        return buffer
    }
}
