import Foundation

/// RFC 4648 §5 base64url, with or without `=` padding.
enum Base64URL {
    private static let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".unicodeScalars)

    /// Decodes base64url text. Whitespace anywhere is ignored so keys typed in groups still work.
    static func decode(_ text: String) -> Data? {
        var scalars = text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
        while scalars.last == "=" { scalars.removeLast() }
        guard !scalars.isEmpty, scalars.count % 4 != 1, scalars.allSatisfy(alphabet.contains) else { return nil }

        var base64 = String(String.UnicodeScalarView(scalars))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }

    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
