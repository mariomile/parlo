import Foundation
import Security

/// LLM API keys, stored as generic passwords in the login keychain, one per server (`LLMSettings.keyScope`):
/// a key saved for one provider is never sent to another.
public enum KeychainStore {
    static let service = "com.mariomiletta.parlo"

    static func account(_ scope: String) -> String { "llm-api-key@\(scope)" }

    static func query(_ scope: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account(scope)]
    }

    public static func read(for scope: String) -> String? {
        var q = query(scope)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        let key = String(decoding: data, as: UTF8.self)
        return key.isEmpty ? nil : key
    }

    /// Saves the key; nil or empty deletes it. The old key stays if the new one can't be written.
    @discardableResult
    public static func save(_ key: String?, for scope: String) -> Bool {
        let query = query(scope)
        guard let key, !key.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let value = [kSecValueData as String: Data(key.utf8)]
        let status = SecItemUpdate(query as CFDictionary, value as CFDictionary)
        guard status == errSecItemNotFound else { return status == errSecSuccess }
        return SecItemAdd(query.merging(value) { $1 } as CFDictionary, nil) == errSecSuccess
    }
}
