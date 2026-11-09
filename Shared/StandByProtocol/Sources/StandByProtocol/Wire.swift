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

    // Milliseconds are handled as integers. Formatting a Double's fraction
    // directly truncates, so a value stored as …793.99999 would print as .793
    // and never survive a round trip.

    public static func formatDate(_ date: Date) -> String {
        let ms = milliseconds(date)
        let (seconds, fraction) = (ms.floorDiv(1000), ms.floorMod(1000))
        let base = Date(timeIntervalSince1970: Double(seconds)).formatted(withoutFraction)   // "…T07:00:00Z"
        return String(base.dropLast()) + String(format: ".%03lldZ", fraction)
    }

    public static func parseDate(_ text: String) -> Date? {
        var base = text
        var fraction: Int64 = 0
        if let dot = text.firstIndex(of: ".") {
            let digits = text[text.index(after: dot)...].prefix { $0.isASCII && $0.isNumber }
            guard !digits.isEmpty else { return nil }
            fraction = Int64(String((digits + "00").prefix(3)))!
            base = String(text[..<dot]) + text[text.index(after: dot)...].dropFirst(digits.count)
        }
        guard let whole = try? Date(base, strategy: withoutFraction) else { return nil }
        return date(milliseconds: milliseconds(whole) + fraction)
    }

    /// `date` as a receiver will decode it: whole milliseconds. Senders apply
    /// this before keeping a message, so what they remember equals what
    /// arrives and a re-send is identical.
    public static func wirePrecision(_ date: Date) -> Date {
        Self.date(milliseconds: milliseconds(date))
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private static func date(milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }

    private static let withoutFraction = Date.ISO8601FormatStyle(timeZone: .gmt)
}

private extension Int64 {
    func floorDiv(_ d: Int64) -> Int64 { (self - floorMod(d)) / d }
    func floorMod(_ d: Int64) -> Int64 { ((self % d) + d) % d }
}
