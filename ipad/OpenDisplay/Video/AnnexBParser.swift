import Foundation

/// Incremental H.264 Annex B parser. Chunks may split NAL units and start codes anywhere.
///
/// A NAL unit is only known to be complete when the next start code arrives, so the parser also
/// reports each new unit's header byte as soon as it lands. That lets the assembler close an
/// access unit the moment an AUD begins instead of waiting for the AUD to finish.
struct AnnexBParser {
    enum Output: Equatable {
        /// A complete NAL unit, header byte first, without start code or trailing zero bytes.
        case nalUnit(Data)
        /// The header byte of a new NAL unit has arrived. `type` is `nal_unit_type`.
        case nalUnitStarted(type: UInt8)
    }

    static let defaultMaximumNALUnitSize = 8 * 1024 * 1024

    let maximumNALUnitSize: Int
    private var buffer: [UInt8] = []
    private var scanIndex = 0
    private var unitStart: Int?
    private var headerReported = false
    private var discardingUnit = false

    init(maximumNALUnitSize: Int = defaultMaximumNALUnitSize) {
        self.maximumNALUnitSize = maximumNALUnitSize
    }

    /// Bytes currently held: at most one partial NAL unit plus two bytes of a possible start code.
    var bufferedByteCount: Int { buffer.count }

    mutating func append(_ chunk: Data) -> [Output] {
        guard !chunk.isEmpty else { return [] }
        buffer.append(contentsOf: chunk)

        var output: [Output] = []
        reportHeader(into: &output)

        var i = scanIndex
        while i + 2 < buffer.count {
            let third = buffer[i + 2]
            // No start code can begin at i, i+1 or i+2 when the third byte is above 1.
            if third > 1 { i += 3; continue }
            if third == 1 && buffer[i] == 0 && buffer[i + 1] == 0 {
                finishUnit(endingAt: i, into: &output)
                unitStart = i + 3
                headerReported = false
                discardingUnit = false
                i += 3
                reportHeader(into: &output)
                continue
            }
            i += 1
        }
        scanIndex = i
        compact()
        return output
    }

    mutating func reset() {
        buffer.removeAll(keepingCapacity: false)
        scanIndex = 0
        unitStart = nil
        headerReported = false
        discardingUnit = false
    }

    private func finishUnit(endingAt startCodeIndex: Int, into output: inout [Output]) {
        guard let start = unitStart, !discardingUnit else { return }
        // Zero bytes before a start code belong to it (4-byte start codes, trailing_zero_8bits).
        var end = startCodeIndex
        while end > start && buffer[end - 1] == 0 { end -= 1 }
        if end > start { output.append(.nalUnit(Data(buffer[start..<end]))) }
    }

    private mutating func reportHeader(into output: inout [Output]) {
        guard !headerReported, !discardingUnit, let start = unitStart, start < buffer.count else { return }
        headerReported = true
        output.append(.nalUnitStarted(type: buffer[start] & 0x1F))
    }

    /// Drops bytes that can no longer matter, keeping memory bounded by `maximumNALUnitSize`.
    private mutating func compact() {
        let dropCount: Int
        if let start = unitStart {
            if discardingUnit || buffer.count - start > maximumNALUnitSize {
                // Oversized unit: forget it and resynchronise at the next start code.
                discardingUnit = true
                dropCount = scanIndex
            } else {
                dropCount = start
            }
        } else {
            // Nothing before the first start code is usable.
            dropCount = scanIndex
        }
        guard dropCount > 0 else { return }
        buffer.removeFirst(dropCount)
        scanIndex -= dropCount
        if let start = unitStart { unitStart = max(0, start - dropCount) }
    }
}
