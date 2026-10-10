import CryptoKit
import Foundation

/// Mutual HMAC-SHA256 handshake from docs/protocol.md. The iPad is the server.
///
///     Windows → iPad   "OPD1" ‖ C                                   36 bytes
///     iPad → Windows   "OPA1" ‖ S ‖ HMAC(key, "server" ‖ C ‖ S)      68 bytes
///     Windows → iPad   HMAC(key, "client" ‖ C ‖ S)                  32 bytes
enum Handshake {
    static let clientMagic = Data("OPD1".utf8)
    static let serverMagic = Data("OPA1".utf8)
    static let nonceLength = 32
    static let macLength = 32
    static let clientHelloLength = 4 + nonceLength
    static let serverHelloLength = 4 + nonceLength + macLength
    static let clientProofLength = macLength
    static let deadline: TimeInterval = 5

    static let clientKeyInfo = Data("OpenDisplay/v1/client".utf8)
    static let serverKeyInfo = Data("OpenDisplay/v1/server".utf8)

    struct SessionKeys {
        /// Windows → iPad (`OpenDisplay/v1/client`).
        let receive: SymmetricKey
        /// iPad → Windows (`OpenDisplay/v1/server`).
        let send: SymmetricKey
    }

    /// Returns C from a client hello, or nil if the bytes aren't an OpenDisplay v1 hello.
    static func clientNonce(fromHello hello: Data) -> Data? {
        let hello = Data(hello)
        guard hello.count == clientHelloLength, hello.prefix(4) == clientMagic else { return nil }
        return Data(hello.suffix(nonceLength))
    }

    static func randomNonce() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    static func serverMAC(key: SymmetricKey, c: Data, s: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data("server".utf8) + c + s, using: key))
    }

    static func clientMAC(key: SymmetricKey, c: Data, s: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data("client".utf8) + c + s, using: key))
    }

    static func serverHello(key: SymmetricKey, c: Data, s: Data) -> Data {
        serverMagic + s + serverMAC(key: key, c: c, s: s)
    }

    /// Constant-time check of the client's proof of key possession.
    static func verifyClientProof(_ proof: Data, key: SymmetricKey, c: Data, s: Data) -> Bool {
        guard proof.count == clientProofLength else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: Data("client".utf8) + c + s, using: key)
    }

    static func sessionKeys(key: SymmetricKey, c: Data, s: Data) -> SessionKeys {
        let salt = c + s
        return SessionKeys(
            receive: HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: salt, info: clientKeyInfo, outputByteCount: 32),
            send: HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: salt, info: serverKeyInfo, outputByteCount: 32)
        )
    }
}
