import Foundation
import Security
import MuxCore

struct SecretStore {
    private let service = "com.linquist.muxmanager.credentials"

    func read(_ account: String, synchronized: Bool = true) throws -> Data? {
        var query = base(account, synchronized: synchronized)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw failure(status) }
        return value as? Data
    }

    func write(_ data: Data, account: String, synchronized: Bool = true) throws {
        let query = base(account, synchronized: synchronized)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let added = SecItemAdd(attributes as CFDictionary, nil)
            guard added == errSecSuccess else { throw failure(added) }
        } else if status != errSecSuccess { throw failure(status) }
    }

    func delete(_ account: String, synchronized: Bool = true) throws {
        let status = SecItemDelete(base(account, synchronized: synchronized) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }

    private func base(_ account: String, synchronized: Bool) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: synchronized]
    }
    private func failure(_ status: OSStatus) -> MuxError {
        .message("Keychain: \(SecCopyErrorMessageString(status, nil) as String? ?? String(status))")
    }
}

struct SavedKeyMaterial: Codable {
    let privateKey: String
    let passphrase: String?
}
