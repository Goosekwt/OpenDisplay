import Foundation
import Security

/// Pairing key in the Keychain (this device only, never synced); PC name and device ID in defaults.
final class PairingStore {
    struct KeychainError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "Keychain error \(status)." }
    }

    private let service = "me.talsa.OpenDisplay.pairing"
    private let account = "pairing-key-v1"
    private let defaults: UserDefaults
    private let pcNameKey = "pairedPCName"
    private let deviceIdKey = "deviceId"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func loadKey() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError(status: status) }
        return data.count == PairingCode.keyLength ? data : nil
    }

    func save(_ code: PairingCode) throws {
        SecItemDelete(baseQuery as CFDictionary)
        var attributes = baseQuery
        attributes[kSecValueData as String] = code.key
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        defaults.set(code.pcName, forKey: pcNameKey)
    }

    func forget() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        defaults.removeObject(forKey: pcNameKey)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    var pcName: String? { defaults.string(forKey: pcNameKey) }

    /// Persistent identifier sent in the iPad hello.
    var deviceId: String {
        if let existing = defaults.string(forKey: deviceIdKey) { return existing }
        let created = UUID().uuidString
        defaults.set(created, forKey: deviceIdKey)
        return created
    }
}
