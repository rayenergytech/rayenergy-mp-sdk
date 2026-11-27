import Foundation
import Security

protocol MpDeviceIdentityStorage {
    func read() throws -> String?
    func saveIfAbsent(_ value: String) throws
}

/// APP-private, this-device identity. A Keychain failure must not become a new registration.
struct MpDeviceKeychain: MpDeviceIdentityStorage {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.nous.mp.device.identity.v1",
         kSecAttrAccount as String: Bundle.main.bundleIdentifier ?? "MpTracker",
         kSecAttrSynchronizable as String: false]
    }
    func read() throws -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data,
              let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            throw NSError(domain: "MpDeviceIdentity", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "设备标识暂时无法读取，请解锁设备后重试；未创建新游客"])
        }
        return value
    }
    func saveIfAbsent(_ value: String) throws {
        var q = query
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        if status == errSecDuplicateItem, try read() == value { return }
        guard status == errSecSuccess else {
            throw NSError(domain: "MpDeviceIdentity", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "设备标识保存失败，请重试；未创建新游客"])
        }
    }
}

struct MpDeviceIdentity {
    let deviceId: String
    let isNewInstall: Bool
    let sessionScope: String
    static func prepare(defaults: UserDefaults, secure: MpDeviceIdentityStorage) throws -> MpDeviceIdentity {
        let local = defaults.string(forKey: "mp_device_id").flatMap { $0.isEmpty ? nil : $0 }
        let saved = try secure.read()
        if let local = local, let saved = saved, local != saved {
            throw NSError(domain: "MpDeviceIdentity", code: 1, userInfo: [NSLocalizedDescriptionKey: "设备标识与已有缓存不一致，停止初始化以避免账号与事件混用"])
        }
        let id = local ?? saved ?? UUID().uuidString
        if saved == nil { try secure.saveIfAbsent(id) }
        // Existing installations retain their old Token namespace. Reinstalls get a new one,
        // so retaining the device identity never restores an old formal login by itself.
        let scope = defaults.string(forKey: "mp_client_installation_scope_v1") ?? (local == nil ? UUID().uuidString : "")
        defaults.set(scope, forKey: "mp_client_installation_scope_v1")
        defaults.set(id, forKey: "mp_device_id")
        return MpDeviceIdentity(deviceId: id, isNewInstall: local == nil, sessionScope: scope)
    }
}
