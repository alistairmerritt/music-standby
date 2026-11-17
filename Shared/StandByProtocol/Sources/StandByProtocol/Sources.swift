import Foundation

/// An Apple Music station a song plays from, for Continue on Mac: the Mac
/// opens the station's link, which plays it, starting on a song of Apple
/// Music's choosing. A station is made as it plays, so the Mac can't start
/// it on the song the phone was playing (17 November 2026).
public struct StationPlace: Codable, Equatable, Sendable {
    /// Apple Music's ID, `ra.…`.
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    /// Only an ID that can go into a link as it is.
    public var isValid: Bool {
        id.hasPrefix("ra.") && id.count <= 128
            && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") }
            && !name.isEmpty && name.count <= PlaylistPlace.maximumNameLength
    }
}

/// Music's repeat setting, carried with a hand-over (17 November 2026). An
/// open set, like `MusicConnection`: a receiver ignores a value it doesn't know.
public struct RepeatMode: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
    public var description: String { rawValue }

    public static let off: RepeatMode = "off"
    public static let one: RepeatMode = "one"
    public static let all: RepeatMode = "all"
}
