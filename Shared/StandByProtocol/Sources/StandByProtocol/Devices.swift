import Foundation

/// What kind of device a `DeviceIdentity` describes. An open set.
public struct DeviceKind: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public static let mac: DeviceKind = "mac"
    public static let iPhone: DeviceKind = "iphone"
}

/// Who a device is. Sent by the Mac in `hello`, and by the relay about the
/// phone in `paired`.
public struct DeviceIdentity: Codable, Equatable, Sendable, Identifiable {
    /// Random, minted on first launch and kept. Never a serial number or a
    /// hardware UUID.
    public var id: String
    /// The user-visible name, e.g. the Mac's Computer Name.
    public var name: String
    public var kind: DeviceKind
    public var appVersion: String?
    public var osVersion: String?

    public init(id: String, name: String, kind: DeviceKind, appVersion: String? = nil, osVersion: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.appVersion = appVersion
        self.osVersion = osVersion
    }
}

/// The phone's record of the Mac it is paired with. Unchanged from the
/// temporary contract.
public struct PairedMac: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    public init(_ device: DeviceIdentity) {
        self.init(id: device.id, name: device.name)
    }
}
