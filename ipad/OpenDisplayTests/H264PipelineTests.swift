import AVFoundation
import CoreMedia
import VideoToolbox
import XCTest
@testable import OpenDisplay

/// Real VideoToolbox H.264 → Annex B → arbitrary chunks → parser → sample buffers → real decode.
final class H264PipelineTests: XCTestCase {
    func testEncodedStreamSurvivesArbitraryChunkingAndDecodes() throws {
        let width = 320, height = 240, frameCount = 12
        let encoded = try EncodedTestStream.make(width: width, height: height, frameCount: frameCount)
        XCTAssertEqual(encoded.keyframes.count, frameCount)
        XCTAssertEqual(encoded.keyframes.first, true)

        var stream = encoded.annexB
        stream.append(contentsOf: [0, 0, 0, 1, 0x09, 0xF0])  // the next AUD closes the last picture

        var parser = AnnexBParser()
        var assembler = AccessUnitAssembler()
        var units: [AccessUnit] = []
        var rng = SeededGenerator(seed: 0x0D15_EA5E)
        var offset = 0
        while offset < stream.count {
            let end = min(stream.count, offset + Int.random(in: 1...97, using: &rng))
            for event in parser.append(stream.subdata(in: offset..<end)) {
                if let unit = assembler.consume(event) { units.append(unit) }
            }
            offset = end
        }

        XCTAssertEqual(units.count, frameCount)
        XCTAssertEqual(units.map(\.isIDR), encoded.keyframes)

        let format = try H264SampleBuilder.formatDescription(for: XCTUnwrap(units.first).parameterSets)
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        XCTAssertEqual(Int(dimensions.width), width)
        XCTAssertEqual(Int(dimensions.height), height)

        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: nil, formatDescription: format, decoderSpecification: nil,
            imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &created)
        guard status == noErr, let session = created else { throw XCTSkip("No H.264 decoder available (status \(status)).") }
        defer { VTDecompressionSessionInvalidate(session) }

        let lock = NSLock()
        var decodedSizes: [CGSize] = []
        var decodeErrors: [OSStatus] = []
        for (index, unit) in units.enumerated() {
            let sample = try H264SampleBuilder.sampleBuffer(
                for: unit, format: format, presentationTime: CMTime(value: CMTimeValue(index), timescale: 30))
            let submitStatus = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
                status, _, image, _, _ in
                lock.lock()
                defer { lock.unlock() }
                if status == noErr, let image {
                    decodedSizes.append(CGSize(width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image)))
                } else {
                    decodeErrors.append(status)
                }
            }
            XCTAssertEqual(submitStatus, noErr, "frame \(index)")
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)

        lock.lock()
        defer { lock.unlock() }
        XCTAssertEqual(decodeErrors, [])
        XCTAssertEqual(decodedSizes.count, frameCount)
        XCTAssertTrue(decodedSizes.allSatisfy { $0 == CGSize(width: width, height: height) })
    }

    func testPictureRefusedByRendererIsDroppedAndDependentsWaitForNextIDR() throws {
        let encoded = try EncodedTestStream.make(width: 320, height: 240, frameCount: 12)
        let marker = Data([0, 0, 0, 1, 0x09, 0xF0])
        var starts: [Int] = []
        var from = encoded.annexB.startIndex
        while let range = encoded.annexB.range(of: marker, in: from..<encoded.annexB.endIndex) {
            starts.append(range.lowerBound)
            from = range.upperBound
        }
        XCTAssertEqual(starts.count, 12)
        let stream = encoded.annexB + marker
        starts.append(encoded.annexB.count)  // closing AUD

        let refused = 2
        guard let nextIDR = encoded.keyframes.indices.first(where: { $0 > refused && encoded.keyframes[$0] }) else {
            throw XCTSkip("Encoder produced no IDR after picture \(refused).")
        }

        let renderer = FakeRenderer()
        let pipeline = VideoPipeline(renderer: renderer)
        for index in starts.indices {
            let end = index + 1 < starts.count ? starts[index + 1] : stream.count
            // The AUD that opens segment `index` completes picture `index - 1`.
            renderer.isReadyForMoreMediaData = index - 1 != refused
            _ = pipeline.consume(stream.subdata(in: starts[index]..<end))
        }

        let expected = [0, 1] + Array(nextIDR..<12)
        XCTAssertEqual(renderer.enqueuedKeyframes, expected.map { encoded.keyframes[$0] })
        XCTAssertEqual(renderer.enqueuedKeyframes[2], true, "the first picture after a drop must be an IDR")
        XCTAssertEqual(pipeline.droppedFrames, 1)
        XCTAssertEqual(pipeline.enqueuedFrames, expected.count)
    }

    func testSampleBufferIsLengthPrefixedAndMarkedForImmediateDisplay() throws {
        let unit = AccessUnit(nalUnits: [Data([0x41, 0x9A, 0x01]), Data([0x41, 0x1A, 0x02, 0x03])], isIDR: false,
                              parameterSets: H264ParameterSets(sps: Data([0x67]), pps: Data([0x68])))
        XCTAssertEqual(hexString(H264SampleBuilder.avccPayload(unit.nalUnits)), "00000003419a0100000004411a0203")

        // Any valid format works for checking attachments; use a real one from the encoder.
        let encoded = try EncodedTestStream.make(width: 64, height: 64, frameCount: 1)
        var parser = AnnexBParser()
        var assembler = AccessUnitAssembler()
        var units: [AccessUnit] = []
        for event in parser.append(encoded.annexB + Data([0, 0, 0, 1, 0x09])) {
            if let unit = assembler.consume(event) { units.append(unit) }
        }
        let format = try H264SampleBuilder.formatDescription(for: XCTUnwrap(units.first).parameterSets)

        let sample = try H264SampleBuilder.sampleBuffer(for: unit, format: format)
        let attachments = try XCTUnwrap(CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as NSArray?)
        let first = try XCTUnwrap(attachments.firstObject as? NSDictionary)
        XCTAssertEqual(first[kCMSampleAttachmentKey_DisplayImmediately as String] as? Bool, true)
        XCTAssertEqual(first[kCMSampleAttachmentKey_NotSync as String] as? Bool, true)
        XCTAssertEqual(CMSampleBufferGetTotalSampleSize(sample), 15)
    }
}

/// Records what the pipeline enqueues; readiness is set by the test.
private final class FakeRenderer: VideoFrameRenderer {
    var status: AVQueuedSampleBufferRenderingStatus = .rendering
    var requiresFlushToResumeDecoding = false
    var isReadyForMoreMediaData = true
    private(set) var enqueuedKeyframes: [Bool] = []

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        enqueuedKeyframes.append(EncodedTestStream.isKeyframe(sampleBuffer))
    }

    func flush() {}
    func flushAndClear() {}
}
