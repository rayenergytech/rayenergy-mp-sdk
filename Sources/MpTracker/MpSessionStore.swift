import Foundation
import Security

/// Separate scopes persist bearer credentials or first acquisition context. Items stay on this device.
final class MpSessionStore {
    private let account: String
    init(scope: [String]) { account = (try! JSONSerialization.data(withJSONObject: scope)).base64EncodedString() }
    private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.nous.mp.client.sessions.v1", kSecAttrAccount as String: account] }
    func read() throws -> String? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?; let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data, let token = String(data: data, encoding: .utf8), !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw failure() }
        return token
    }
    func write(_ token: String?) throws {
        guard let token = token else { let status = SecItemDelete(query as CFDictionary); guard status == errSecSuccess || status == errSecItemNotFound else { throw failure() }; return }
        let values: [String: Any] = [kSecValueData as String: Data(token.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound { var q = query; values.forEach { q[$0.key] = $0.value }; guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw failure() } }
        else if status != errSecSuccess { throw failure() }
    }
    private func failure() -> NSError { NSError(domain: "MpSessionStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Token cache unavailable"]) }
}
