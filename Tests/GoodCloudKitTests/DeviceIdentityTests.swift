import XCTest
@testable import GoodCloudKit

final class DeviceIdentityTests: XCTestCase {
    func test_persistentStore_isStableAcrossInstances() {
        let suite = UserDefaults(suiteName: "gck.test.\(UUID().uuidString)")!
        let a = PersistentDeviceIdentityStore(defaults: suite).identity()
        let b = PersistentDeviceIdentityStore(defaults: suite).identity()
        XCTAssertEqual(a, b)                      // persisted, not regenerated
        XCTAssertNotEqual(a.deviceId, a.singleId) // two distinct ids
        XCTAssertFalse(a.deviceId.isEmpty)
    }

    func test_fixedStore_returnsInjected() {
        let s = FixedDeviceIdentityStore(deviceId: "d", singleId: "s")
        XCTAssertEqual(s.identity(), DeviceIdentity(deviceId: "d", singleId: "s"))
    }
}
