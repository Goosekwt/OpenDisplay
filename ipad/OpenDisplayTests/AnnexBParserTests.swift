import XCTest
@testable import OpenDisplay

final class AnnexBParserTests: XCTestCase {
    // Hand-built NAL units. None ends in 0x00, and the slices carry emulation-prevention bytes.
    private let aud = Data([0x09, 0xF0])
    private let sps = Data([0x67, 0x42, 0xC0, 0x1E, 0xDA, 0x02, 0x80, 0xBF])
    private let pps = Data([0x68, 0xCE, 0x3C, 0x80])
    private let idr = Data([0x65, 0x88, 0x84, 0x00, 0x21, 0xFF, 0x00, 0x00, 0x03, 0x01, 0x7A])
    private let p1 = Data([0x41, 0x9A, 0x02, 0x10, 0x00, 0x00, 0x03, 0x00, 0x55])
    private let p2 = Data([0x41, 0x9A, 0x04, 0x20, 0x33])

    private let short = Data([0, 0, 1])
    private let long = Data([0, 0, 0, 1])

    /// AUD SPS PPS IDR | AUD P1 | AUD P2 | AUD — the trailing AUD closes P2's access unit.
    private var stream: Data {
        join([long, aud, long, sps, long, pps, short, idr,
              long, aud, short, p1,
              long, aud, long, p2,
              long, aud])
    }

    /// Concatenates parts; long `Data + Data` chains defeat the type checker.
    private func join(_ parts: [Data]) -> Data {
        parts.reduce(into: Data()) { $0.append($1) }
    }

    private var expectedNALs: [Data] { [aud, sps, pps, idr, aud, p1, aud, p2] }

    private var expectedUnits: [AccessUnit] {
        let sets = H264ParameterSets(sps: sps, pps: pps)
        return [
            AccessUnit(nalUnits: [idr], isIDR: true, parameterSets: sets),
            AccessUnit(nalUnits: [p1], isIDR: false, parameterSets: sets),
            AccessUnit(nalUnits: [p2], isIDR: false, parameterSets: sets),
        ]
    }

    private struct Result {
        var nalUnits: [Data] = []
        var accessUnits: [AccessUnit] = []
    }

    private func run(_ chunks: [Data], parser: inout AnnexBParser, assembler: inout AccessUnitAssembler) -> Result {
        var result = Result()
        for chunk in chunks {
            for event in parser.append(chunk) {
                if case .nalUnit(let nal) = event { result.nalUnits.append(nal) }
                if let unit = assembler.consume(event) { result.accessUnits.append(unit) }
            }
        }
        return result
    }

    private func run(_ chunks: [Data]) -> Result {
        var parser = AnnexBParser()
        var assembler = AccessUnitAssembler()
        return run(chunks, parser: &parser, assembler: &assembler)
    }

    private func chunked(_ data: Data, sizes: [Int]) -> [Data] {
        var chunks: [Data] = []
        var offset = 0
        var index = 0
        while offset < data.count {
            let end = min(data.count, offset + sizes[index % sizes.count])
            chunks.append(data.subdata(in: offset..<end))
            offset = end
            index += 1
        }
        return chunks
    }

    func testWholeStream() {
        let result = run([stream])
        XCTAssertEqual(result.nalUnits, expectedNALs)
        XCTAssertEqual(result.accessUnits, expectedUnits)
    }

    func testOneByteAtATime() {
        let result = run(chunked(stream, sizes: [1]))
        XCTAssertEqual(result.nalUnits, expectedNALs)
        XCTAssertEqual(result.accessUnits, expectedUnits)
    }

    func testEverySplitPointIncludingInsideStartCodes() {
        let data = stream
        for split in 1..<data.count {
            let result = run([data.subdata(in: 0..<split), data.subdata(in: split..<data.count)])
            XCTAssertEqual(result.nalUnits, expectedNALs, "split at \(split)")
            XCTAssertEqual(result.accessUnits, expectedUnits, "split at \(split)")
        }
    }

    func testRandomChunkBoundaries() {
        var rng = SeededGenerator(seed: 42)
        let data = stream
        for round in 0..<500 {
            let sizes = (0..<8).map { _ in Int.random(in: 1...9, using: &rng) }
            let result = run(chunked(data, sizes: sizes))
            XCTAssertEqual(result.nalUnits, expectedNALs, "round \(round) sizes \(sizes)")
            XCTAssertEqual(result.accessUnits, expectedUnits, "round \(round) sizes \(sizes)")
        }
    }

    func testAccessUnitIsEmittedAsSoonAsTheNextAUDHeaderArrives() {
        // Stops right after the AUD header byte that follows P1, before the AUD is complete.
        let partial = join([long, aud, long, sps, long, pps, short, idr, long, aud, short, p1, long, Data([0x09])])
        let result = run([partial])
        XCTAssertEqual(result.accessUnits, Array(expectedUnits.prefix(2)))
    }

    func testIgnoresBytesBeforeFirstStartCode() {
        let result = run([Data([0x12, 0x34, 0x00, 0x56]), stream])
        XCTAssertEqual(result.nalUnits, expectedNALs)
        XCTAssertEqual(result.accessUnits, expectedUnits)
    }

    func testWaitsForIDRBeforeEmittingPictures() {
        // Joins mid-stream: a P picture before any IDR must be dropped.
        let data = join([long, aud, short, p1, long, aud, long, sps, long, pps, long, idr, long, aud, long, p2, long, aud])
        let units = run([data]).accessUnits
        XCTAssertEqual(units.map(\.isIDR), [true, false])
        XCTAssertEqual(units.first?.nalUnits, [idr])
    }

    func testDropsPicturesUntilParameterSetsArrive() {
        let data = join([long, aud, long, idr, long, aud, long, p1, long, aud])
        XCTAssertEqual(run([data]).accessUnits, [])
    }

    func testRetainsParameterSetsForLaterPictures() {
        let units = run([stream]).accessUnits
        XCTAssertEqual(units.last?.parameterSets, H264ParameterSets(sps: sps, pps: pps))
    }

    func testSplitsPicturesWhenAUDsAreMissing() {
        let data = join([long, sps, long, pps, long, idr, long, p1, short, p2, long, aud])
        XCTAssertEqual(run([data]).accessUnits, expectedUnits)
    }

    func testKeepsMultiSlicePictureTogether() {
        // Second slice has first_mb_in_slice != 0 (top bit of its second byte is clear).
        let secondSlice = Data([0x65, 0x40, 0x11, 0x22])
        let data = join([long, aud, long, sps, long, pps, long, idr, long, secondSlice, long, aud])
        let units = run([data]).accessUnits
        XCTAssertEqual(units.count, 1)
        XCTAssertEqual(units.first?.nalUnits, [idr, secondSlice])
    }

    func testOversizedNALUnitIsDroppedAndParserResynchronises() {
        var parser = AnnexBParser(maximumNALUnitSize: 32)
        var assembler = AccessUnitAssembler()
        let huge = Data([0x41, 0x9A]) + Data(repeating: 0x55, count: 300)
        let data = join([long, aud, long, sps, long, pps, long, idr, long, aud, long, huge, long, aud, short, p1, long, aud])

        var result = Result()
        for chunk in chunked(data, sizes: [10, 3, 7]) {
            result.nalUnits += run([chunk], parser: &parser, assembler: &assembler).nalUnits
            XCTAssertLessThanOrEqual(parser.bufferedByteCount, 32 + 2)
        }
        XCTAssertFalse(result.nalUnits.contains(huge))
        XCTAssertTrue(result.nalUnits.contains(p1))
    }

    func testOversizedAccessUnitIsDroppedUntilNextIDR() {
        var parser = AnnexBParser()
        var assembler = AccessUnitAssembler(maximumAccessUnitSize: 16)
        let data = join([long, aud, long, sps, long, pps, long, idr, long, aud, long, p1, long, aud, long, p2, long, aud])
        // Every picture here fits a 16-byte limit: IDR 11 bytes, P1 9, P2 5.
        let units = run([data], parser: &parser, assembler: &assembler).accessUnits
        XCTAssertEqual(units.count, 3)

        var tight = AccessUnitAssembler(maximumAccessUnitSize: 10)
        var freshParser = AnnexBParser()
        // The 11-byte IDR overflows, so nothing decodable follows until another IDR arrives.
        XCTAssertEqual(run([data], parser: &freshParser, assembler: &tight).accessUnits, [])
    }

    func testResetDiscardsPartialState() {
        var parser = AnnexBParser()
        var assembler = AccessUnitAssembler()
        let data = stream
        _ = run([data.subdata(in: 0..<(data.count / 2))], parser: &parser, assembler: &assembler)
        parser.reset()
        assembler.reset()
        XCTAssertEqual(parser.bufferedByteCount, 0)
        XCTAssertNil(assembler.sps)
        let result = run([data], parser: &parser, assembler: &assembler)
        XCTAssertEqual(result.nalUnits, expectedNALs)
        XCTAssertEqual(result.accessUnits, expectedUnits)
    }
}
