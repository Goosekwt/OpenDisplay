import Foundation

struct H264ParameterSets: Equatable {
    var sps: Data
    var pps: Data
}

/// One coded picture: its VCL NAL units in decode order, plus the parameter sets it decodes with.
struct AccessUnit: Equatable {
    var nalUnits: [Data]
    var isIDR: Bool
    var parameterSets: H264ParameterSets
}

/// Groups NAL units into access units at AUD boundaries (H.264 §7.4.1.2.3), retaining SPS/PPS.
/// Also splits on the other access-unit-starting NAL types and on a new picture's first slice,
/// so a stream that drops an AUD still decodes. Nothing is emitted until an IDR arrives.
struct AccessUnitAssembler {
    static let defaultMaximumAccessUnitSize = 16 * 1024 * 1024

    let maximumAccessUnitSize: Int
    private(set) var sps: Data?
    private(set) var pps: Data?
    private(set) var waitingForIDR = true
    private var nalUnits: [Data] = []
    private var byteCount = 0
    private var hasVCL = false
    private var containsIDR = false
    private var overflowed = false

    init(maximumAccessUnitSize: Int = defaultMaximumAccessUnitSize) {
        self.maximumAccessUnitSize = maximumAccessUnitSize
    }

    /// Returns the access unit this event completed, if any.
    mutating func consume(_ event: AnnexBParser.Output) -> AccessUnit? {
        switch event {
        case .nalUnitStarted(let type):
            return hasVCL && Self.beginsAccessUnit(type) ? finishAccessUnit() : nil

        case .nalUnit(let nal):
            guard let header = nal.first else { return nil }
            let type = header & 0x1F
            var completed: AccessUnit?
            if hasVCL && (Self.beginsAccessUnit(type) || Self.isFirstSliceOfNewPicture(nal)) {
                completed = finishAccessUnit()
            }
            switch type {
            case 7: sps = nal
            case 8: pps = nal
            case 1...5: appendVCL(nal, isIDR: type == 5)
            default: break  // AUD, SEI, filler: the decoder doesn't need them.
            }
            return completed
        }
    }

    /// After a decode failure, drop pictures until the next IDR.
    mutating func requestIDR() {
        waitingForIDR = true
    }

    mutating func reset() {
        sps = nil
        pps = nil
        waitingForIDR = true
        clearPending()
    }

    private mutating func appendVCL(_ nal: Data, isIDR: Bool) {
        hasVCL = true
        containsIDR = containsIDR || isIDR
        guard !overflowed else { return }
        byteCount += nal.count
        if byteCount > maximumAccessUnitSize {
            overflowed = true
            nalUnits.removeAll()
        } else {
            nalUnits.append(nal)
        }
    }

    private mutating func finishAccessUnit() -> AccessUnit? {
        defer { clearPending() }
        guard hasVCL else { return nil }
        guard !overflowed, let sps, let pps else {
            waitingForIDR = true
            return nil
        }
        if waitingForIDR {
            guard containsIDR else { return nil }
            waitingForIDR = false
        }
        return AccessUnit(nalUnits: nalUnits, isIDR: containsIDR, parameterSets: H264ParameterSets(sps: sps, pps: pps))
    }

    private mutating func clearPending() {
        nalUnits = []
        byteCount = 0
        hasVCL = false
        containsIDR = false
        overflowed = false
    }

    /// SEI, SPS, PPS, AUD and types 14–18 start a new access unit when they follow a VCL NAL unit.
    static func beginsAccessUnit(_ type: UInt8) -> Bool {
        switch type {
        case 6, 7, 8, 9, 14...18: true
        default: false
        }
    }

    /// `first_mb_in_slice == 0` is ue(v) "1", i.e. the top bit of the byte after the header.
    static func isFirstSliceOfNewPicture(_ nal: Data) -> Bool {
        guard let header = nal.first, [1, 2, 5].contains(header & 0x1F),
              let firstPayloadByte = nal.dropFirst().first
        else { return false }
        return firstPayloadByte & 0x80 != 0
    }
}
