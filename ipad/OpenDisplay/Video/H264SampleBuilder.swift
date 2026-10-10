import CoreMedia
import Foundation

/// Turns parsed H.264 into Core Media objects that AVSampleBufferDisplayLayer or VideoToolbox decode.
enum H264SampleBuilder {
    enum BuildError: Error {
        case formatDescription(OSStatus)
        case blockBuffer(OSStatus)
        case sampleBuffer(OSStatus)
    }

    static func formatDescription(for sets: H264ParameterSets) throws -> CMVideoFormatDescription {
        var description: CMFormatDescription?
        let status = sets.sps.withUnsafeBytes { (sps: UnsafeRawBufferPointer) -> OSStatus in
            sets.pps.withUnsafeBytes { (pps: UnsafeRawBufferPointer) -> OSStatus in
                guard let spsBase = sps.baseAddress, let ppsBase = pps.baseAddress else { return kCMFormatDescriptionError_InvalidParameter }
                let pointers: [UnsafePointer<UInt8>] = [
                    spsBase.assumingMemoryBound(to: UInt8.self),
                    ppsBase.assumingMemoryBound(to: UInt8.self),
                ]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &description
                )
            }
        }
        guard status == noErr, let description else { throw BuildError.formatDescription(status) }
        return description
    }

    /// Length-prefixed (AVCC) form: each NAL unit preceded by its 4-byte big-endian size.
    static func avccPayload(_ nalUnits: [Data]) -> Data {
        var payload = Data(capacity: nalUnits.reduce(0) { $0 + 4 + $1.count })
        for nal in nalUnits {
            withUnsafeBytes(of: UInt32(nal.count).bigEndian) { payload.append(contentsOf: $0) }
            payload.append(nal)
        }
        return payload
    }

    /// One sample per access unit, marked to display immediately.
    static func sampleBuffer(
        for unit: AccessUnit,
        format: CMVideoFormatDescription,
        presentationTime: CMTime = CMClockGetTime(CMClockGetHostTimeClock())
    ) throws -> CMSampleBuffer {
        let payload = avccPayload(unit.nalUnits)

        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: payload.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: payload.count,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block
        )
        guard status == kCMBlockBufferNoErr, let block else { throw BuildError.blockBuffer(status) }

        status = payload.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: payload.count)
        }
        guard status == kCMBlockBufferNoErr else { throw BuildError.blockBuffer(status) }

        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: presentationTime, decodeTimeStamp: .invalid)
        var sampleSize = payload.count
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sample
        )
        guard status == noErr, let sample else { throw BuildError.sampleBuffer(status) }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as NSArray?,
           let first = attachments.firstObject as? NSMutableDictionary {
            first[kCMSampleAttachmentKey_DisplayImmediately as String] = true
            if !unit.isIDR { first[kCMSampleAttachmentKey_NotSync as String] = true }
        }
        return sample
    }
}
