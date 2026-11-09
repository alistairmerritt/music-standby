import Foundation

/// Version and JSON coding rules for everything in this package.
///
/// Encode and decode wire JSON with `StandByWire.makeEncoder()` and
/// `StandByWire.makeDecoder()`. A default `JSONEncoder` writes `Date` as a bare
/// number of seconds since 2001, which nothing else on the wire understands.
public enum StandByWire {
    /// The protocol version this build speaks. Sent in `hello` and `welcome`.
    ///
    /// Additive changes — a new optional field, a new frame type, a new
    /// `ErrorCode` — do not change it. Anything an older peer would misread does.
    public static let version = 1

    /// ISO-8601, UTC, millisecond precision: `2026-11-09T07:00:00.250Z`.
    /// Keys are sorted so the output is stable for tests and diffs.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatDate(date))
        }
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// Accepts ISO-8601 with or without fractional seconds. Rejects numbers:
    /// an epoch in seconds and one in milliseconds are too easy to confuse.
    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = parseDate(text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected an ISO-8601 date, got \(text)")
            }
            return date
        }
        return decoder
    }

    public static func formatDate(_ date: Date) -> String {
        date.formatted(withFraction)
    }

    public static func parseDate(_ text: String) -> Date? {
        (try? Date(text, strategy: withFraction)) ?? (try? Date(text, strategy: withoutFraction))
    }

    private static let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt)
    private static let withoutFraction = Date.ISO8601FormatStyle(timeZone: .gmt)
}
