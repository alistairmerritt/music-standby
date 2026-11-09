import CoreGraphics
import Foundation
import ImageIO

/// The image formats the app accepts. The Mac uploads one of these
/// (`ArtworkDescriptor.contentType`).
public enum ArtworkFormat: String, Equatable, Sendable {
    case png = "image/png"
    case jpeg = "image/jpeg"

    /// Decides from the bytes themselves, since a header is only a claim.
    public static func sniff(_ data: Data) -> ArtworkFormat? {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg }
        return nil
    }
}

/// What makes artwork acceptable. A push payload can name any URL, so nothing
/// is fetched or handed to the system without passing here.
public struct ArtworkPolicy: Equatable, Sendable {
    public var maximumByteCount: Int
    public var maximumPixelDimension: Int
    public var timeout: TimeInterval

    public init(
        maximumByteCount: Int = ArtworkDescriptor.maximumByteCount,
        maximumPixelDimension: Int = 4096,
        timeout: TimeInterval = 10
    ) {
        self.maximumByteCount = maximumByteCount
        self.maximumPixelDimension = maximumPixelDimension
        self.timeout = timeout
    }

    /// HTTPS, to exactly the configured relay host. With no relay configured
    /// nothing is trusted, so nothing is fetched.
    public func validate(url: URL, allowedHost: String?) throws {
        guard url.scheme?.lowercased() == "https",
              let allowedHost,
              url.host()?.lowercased() == allowedHost.lowercased(),
              url.port == nil || url.port == 443,
              url.user() == nil
        else { throw TransportError.artworkUnavailable }
    }

    /// Checks the bytes without decoding the pixels.
    @discardableResult
    public func validate(data: Data, contentType: String?) throws -> ArtworkFormat {
        guard !data.isEmpty, data.count <= maximumByteCount, let format = ArtworkFormat.sniff(data) else {
            throw TransportError.artworkUnavailable
        }
        if let contentType {
            let mediaType = contentType.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased()
            guard mediaType == ArtworkFormat.png.rawValue || mediaType == ArtworkFormat.jpeg.rawValue else {
                throw TransportError.artworkUnavailable
            }
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= maximumPixelDimension, height <= maximumPixelDimension
        else { throw TransportError.artworkUnavailable }
        return format
    }
}

/// Fetches artwork that is not on the device yet.
public protocol ArtworkFetching: Sendable {
    /// A URL from a push payload.
    func fetch(url: URL) async throws -> Data
    /// By content hash, from the relay's artwork endpoint.
    func fetch(id: String) async throws -> Data
}
