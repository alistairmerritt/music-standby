import Foundation

public struct PairingCode: Equatable, Sendable {
    public static let length = 6
    public let value: String

    public init?(_ raw: String) {
        guard raw.count == Self.length, raw.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        value = raw
    }

    /// Reduces arbitrary typed or pasted text to at most six digits.
    public static func sanitise(_ raw: String) -> String {
        String(raw.filter { $0.isASCII && $0.isNumber }.prefix(length))
    }
}

public struct PairingStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "pairedMac"

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public var pairedMac: PairedMac? {
        get { defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(PairedMac.self, from: $0) } }
        nonmutating set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }
}
