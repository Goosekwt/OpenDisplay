import Foundation

/// A pairing key received from the PC, either from the QR link
/// `opendisplay://pair?v=1&key=<base64url>&name=<PC name>` or typed in as a bare base64url key.
struct PairingCode: Equatable {
    static let keyLength = 32
    static let maximumNameLength = 64

    let key: Data
    let pcName: String?

    enum ParseError: LocalizedError, Equatable {
        case empty
        case notOpenDisplayLink
        case unsupportedVersion
        case missingKey
        case invalidKey

        var errorDescription: String? {
            switch self {
            case .empty: "Enter the pairing key shown on your PC."
            case .notOpenDisplayLink: "This isn't an OpenDisplay pairing code."
            case .unsupportedVersion: "This pairing code is from a newer version of OpenDisplay. Update the app on this iPad."
            case .missingKey: "The pairing code doesn't contain a key."
            case .invalidKey: "The key isn't valid. Check that all 43 characters were entered exactly."
            }
        }
    }

    init(key: Data, pcName: String?) {
        self.key = key
        self.pcName = pcName
    }

    static func parse(_ input: String) throws -> PairingCode {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ParseError.empty }

        guard text.range(of: "://") != nil || text.lowercased().hasPrefix("opendisplay:") else {
            return PairingCode(key: try decodeKey(text), pcName: nil)
        }

        guard let components = URLComponents(string: text),
              components.scheme?.lowercased() == "opendisplay",
              components.host?.lowercased() == "pair"
        else { throw ParseError.notOpenDisplayLink }

        let items = components.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        guard value("v") == "1" else { throw ParseError.unsupportedVersion }
        guard let keyText = value("key"), !keyText.isEmpty else { throw ParseError.missingKey }
        return PairingCode(key: try decodeKey(keyText), pcName: sanitizedName(value("name")))
    }

    static func sanitizedName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let cleaned = String(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(maximumNameLength))
    }

    private static func decodeKey(_ text: String) throws -> Data {
        guard let key = Base64URL.decode(text), key.count == keyLength else { throw ParseError.invalidKey }
        return key
    }
}

// The key must never reach logs, crash reports or debugger summaries by accident.
extension PairingCode: CustomStringConvertible, CustomDebugStringConvertible {
    var description: String { "PairingCode(pc: \(pcName ?? "unnamed"), key: <redacted>)" }
    var debugDescription: String { description }
}
