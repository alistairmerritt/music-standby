import Foundation
import StandByProtocol

/// What the companion keeps between launches.
public final class CompanionStore: @unchecked Sendable {
    // UserDefaults is thread-safe; this class adds no state of its own.
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private enum Key {
        static let lastRevision = "lastRevision"
        static let deviceID = "deviceID"
    }

    /// Written before each state frame is sent, so a crash can't reuse it.
    public var lastRevision: UInt64? {
        get { (defaults.object(forKey: Key.lastRevision) as? NSNumber)?.uint64Value }
        set {
            if let newValue { defaults.set(NSNumber(value: newValue), forKey: Key.lastRevision) }
            else { defaults.removeObject(forKey: Key.lastRevision) }
        }
    }

    /// Random, minted on first use. Never a serial number.
    public func deviceID() -> String {
        if let id = defaults.string(forKey: Key.deviceID) { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: Key.deviceID)
        return id
    }

    public func deviceIdentity(name: String, appVersion: String?) -> DeviceIdentity {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return DeviceIdentity(id: deviceID(), name: name, kind: .mac, appVersion: appVersion,
                              osVersion: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)")
    }
}
