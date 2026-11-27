import XCTest
@testable import MpTracker

final class MpDeviceIdentityTests: XCTestCase {
    final class MemoryKeychain: MpDeviceIdentityStorage {
        var value: String?
        var unavailable = false
        func read() throws -> String? {
            if unavailable { throw NSError(domain: "test", code: 1) }
            return value
        }
        func saveIfAbsent(_ value: String) throws { self.value = value }
    }
    var defaults: UserDefaults!
    var suite: String!
    override func setUp() {
        suite = "MpDeviceIdentityTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
    }
    override func tearDown() { defaults.removePersistentDomain(forName: suite) }
    func testReinstallRetainsDeviceButNotFormalLoginNamespace() throws {
        let keychain = MemoryKeychain()
        let first = try MpDeviceIdentity.prepare(defaults: defaults, secure: keychain)
        let restart = try MpDeviceIdentity.prepare(defaults: defaults, secure: keychain)
        XCTAssertEqual(first.deviceId, restart.deviceId)
        XCTAssertEqual(first.sessionScope, restart.sessionScope)
        XCTAssertFalse(restart.isNewInstall)
        defaults.removePersistentDomain(forName: suite) // Uninstall removes sandbox, not the test Keychain.
        let reinstalled = try MpDeviceIdentity.prepare(defaults: defaults, secure: keychain)
        XCTAssertEqual(first.deviceId, reinstalled.deviceId)
        XCTAssertNotEqual(first.sessionScope, reinstalled.sessionScope)
        XCTAssertTrue(reinstalled.isNewInstall)
    }
    func testUpgradeMigratesOriginalIdAndRetainsExistingTokenNamespace() throws {
        defaults.set("original-device", forKey: "mp_device_id")
        let keychain = MemoryKeychain()
        let migrated = try MpDeviceIdentity.prepare(defaults: defaults, secure: keychain)
        XCTAssertEqual("original-device", keychain.value)
        XCTAssertEqual("", migrated.sessionScope)
        defaults.removePersistentDomain(forName: suite)
        XCTAssertEqual(migrated.deviceId, try MpDeviceIdentity.prepare(defaults: defaults, secure: keychain).deviceId)
    }
    func testLockedKeychainDoesNotGenerateNewIdentity() {
        let keychain = MemoryKeychain(); keychain.unavailable = true
        XCTAssertThrowsError(try MpDeviceIdentity.prepare(defaults: defaults, secure: keychain))
        XCTAssertNil(defaults.string(forKey: "mp_device_id"))
        XCTAssertNil(defaults.string(forKey: "mp_client_installation_scope_v1"))
    }
    func testConflictingHistoryDoesNotMixQueuedEventsOrAccounts() {
        defaults.set("local", forKey: "mp_device_id")
        let keychain = MemoryKeychain(); keychain.value = "other"
        XCTAssertThrowsError(try MpDeviceIdentity.prepare(defaults: defaults, secure: keychain))
        XCTAssertEqual("local", defaults.string(forKey: "mp_device_id"))
        XCTAssertEqual("other", keychain.value)
    }
}
