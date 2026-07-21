import Foundation

public struct DeviceIdentity: Sendable, Equatable {
    public let deviceId: String
    public let singleId: String
    public init(deviceId: String, singleId: String) {
        self.deviceId = deviceId
        self.singleId = singleId
    }
}

public protocol DeviceIdentityStore: Sendable {
    func identity() -> DeviceIdentity
}

/// Test/support store that returns an injected identity.
public struct FixedDeviceIdentityStore: DeviceIdentityStore {
    private let value: DeviceIdentity
    public init(deviceId: String, singleId: String) {
        value = DeviceIdentity(deviceId: deviceId, singleId: singleId)
    }
    public func identity() -> DeviceIdentity { value }
}

/// Generates two UUIDs once and persists them in `UserDefaults`; returns the same identity thereafter.
public final class PersistentDeviceIdentityStore: DeviceIdentityStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let lock = NSLock()
    private let deviceKey = "xyz.goodcloud.GoodCloudKit.deviceId"
    private let singleKey = "xyz.goodcloud.GoodCloudKit.singleId"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func identity() -> DeviceIdentity {
        lock.lock(); defer { lock.unlock() }
        let deviceId = defaults.string(forKey: deviceKey) ?? persist(UUID().uuidString, forKey: deviceKey)
        let singleId = defaults.string(forKey: singleKey) ?? persist(UUID().uuidString, forKey: singleKey)
        return DeviceIdentity(deviceId: deviceId, singleId: singleId)
    }

    private func persist(_ value: String, forKey key: String) -> String {
        defaults.set(value, forKey: key)
        return value
    }
}
