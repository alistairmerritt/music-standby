import Foundation

/// One place Music can play to: the Mac itself or an AirPlay device, as
/// Music's `AirPlay device` class lists them. Added 11 November 2026.
public struct AudioOutput: Codable, Equatable, Sendable, Identifiable {
    /// Music's `kind`. Open: an unknown value decodes as `.unknown`.
    public struct Kind: RawRepresentable, Codable, Equatable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
        public func encode(to encoder: Encoder) throws { try rawValue.encode(to: encoder) }

        public static let computer = Kind(rawValue: "computer")
        public static let airportExpress = Kind(rawValue: "airport_express")
        public static let appleTV = Kind(rawValue: "apple_tv")
        public static let airPlay = Kind(rawValue: "airplay")
        public static let bluetooth = Kind(rawValue: "bluetooth")
        public static let homePod = Kind(rawValue: "homepod")
        public static let tv = Kind(rawValue: "tv")
        public static let unknown = Kind(rawValue: "unknown")
    }

    /// Stable for one Mac: the device's network address when Music has one,
    /// otherwise `name:<name>`. `RemoteCommand.outputID` names one of these.
    public var id: String
    public var name: String
    public var kind: Kind
    /// Music is playing to this device now. Several can be selected at once.
    public var isSelected: Bool
    /// Reachable right now. An unavailable device is listed but can't be chosen.
    public var isAvailable: Bool

    public init(id: String, name: String, kind: Kind, isSelected: Bool, isAvailable: Bool = true) {
        self.id = id
        self.name = name
        self.kind = kind
        self.isSelected = isSelected
        self.isAvailable = isAvailable
    }

    /// The id the Mac builds for a device.
    public static func makeID(networkAddress: String?, name: String) -> String {
        if let address = networkAddress?.trimmingCharacters(in: .whitespacesAndNewlines), !address.isEmpty {
            return address.lowercased()
        }
        return "name:" + name
    }
}
