import XCTest
@testable import OpenDisplay

final class PairingCodeTests: XCTestCase {
    /// base64url of bytes 00..1f. Synthetic, not a real pairing key.
    private let keyText = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"

    func testParsesQRLink() throws {
        let code = try PairingCode.parse("opendisplay://pair?v=1&key=\(keyText)&name=Office%20PC")
        XCTAssertEqual(code.key, Vectors.pairingKey)
        XCTAssertEqual(code.pcName, "Office PC")
    }

    func testParsesLinkWithoutNameAndWithPaddedKey() throws {
        let code = try PairingCode.parse("  opendisplay://pair?key=\(keyText)=&v=1\n")
        XCTAssertEqual(code.key, Vectors.pairingKey)
        XCTAssertNil(code.pcName)
    }

    func testParsesBareKeyTypedInGroups() throws {
        let grouped = stride(from: 0, to: keyText.count, by: 4).map { offset -> String in
            let start = keyText.index(keyText.startIndex, offsetBy: offset)
            let end = keyText.index(start, offsetBy: min(4, keyText.count - offset))
            return String(keyText[start..<end])
        }.joined(separator: " ")
        XCTAssertEqual(try PairingCode.parse(grouped).key, Vectors.pairingKey)
    }

    func testBase64URLAlphabetRoundTrips() {
        let key = Data((0..<32).map { UInt8(255 - $0 * 3) })
        let encoded = Base64URL.encode(key)
        XCTAssertEqual(encoded.count, 43)
        XCTAssertNil(encoded.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
        XCTAssertEqual(Base64URL.decode(encoded), key)
        XCTAssertEqual(try PairingCode.parse(encoded).key, key)
    }

    func testRejectsInvalidInput() {
        let cases: [(String, PairingCode.ParseError)] = [
            ("", .empty),
            ("   ", .empty),
            ("https://example.com/pair?v=1&key=\(keyText)", .notOpenDisplayLink),
            ("opendisplay://other?v=1&key=\(keyText)", .notOpenDisplayLink),
            ("opendisplay://pair?v=2&key=\(keyText)", .unsupportedVersion),
            ("opendisplay://pair?key=\(keyText)", .unsupportedVersion),
            ("opendisplay://pair?v=1", .missingKey),
            ("opendisplay://pair?v=1&key=\(keyText.dropLast(4))", .invalidKey),
            (String(keyText.dropLast()) + "!", .invalidKey),
            (keyText + "AAAA", .invalidKey),
            (keyText.replacingOccurrences(of: "A", with: "+"), .invalidKey),
        ]
        for (input, expected) in cases {
            XCTAssertThrowsError(try PairingCode.parse(input), input) {
                XCTAssertEqual($0 as? PairingCode.ParseError, expected, input)
            }
        }
    }

    func testNameIsCleanedAndBounded() throws {
        let long = String(repeating: "x", count: 200)
        let code = try PairingCode.parse("opendisplay://pair?v=1&key=\(keyText)&name=%0A%20\(long)")
        XCTAssertEqual(code.pcName?.count, PairingCode.maximumNameLength)
        XCTAssertNil(try PairingCode.parse("opendisplay://pair?v=1&key=\(keyText)&name=%20%0A").pcName)
    }

    func testDescriptionNeverContainsKey() throws {
        let code = try PairingCode.parse("opendisplay://pair?v=1&key=\(keyText)&name=Desk")
        for text in [String(describing: code), String(reflecting: code), "\(code)"] {
            XCTAssertFalse(text.contains(keyText))
            XCTAssertFalse(text.contains(hexString(code.key)))
            XCTAssertTrue(text.contains("redacted"))
        }
    }
}
