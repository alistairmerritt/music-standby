import CryptoKit
import Foundation

/// How album art is named.
///
/// An artwork id is the lowercase hex SHA-256 of the image bytes **exactly as
/// Music.app returns them** (`raw data of artwork 1`), before any resizing or
/// re-encoding. Those bytes were verified byte-stable across repeated reads, so
/// the same album always gets the same id, whatever encoder the Mac later uses
/// to make the copy it uploads. The id is therefore a cache key, not a checksum
/// of the upload; `ArtworkDescriptor` describes the bytes actually served.
public enum ArtworkID {
    public static func make(sourceBytes: Data) -> String {
        SHA256.hash(data: sourceBytes).map { String(format: "%02x", $0) }.joined()
    }

    /// 64 lowercase hex characters.
    public static func isValid(_ id: String) -> Bool {
        id.utf8.count == 64 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

/// The image served for an artwork id: what the Mac uploads, or what the
/// relay stores. Announced in an `artwork` frame.
public struct ArtworkDescriptor: Codable, Equatable, Sendable {
    public var artworkID: String
    /// `image/jpeg` or `image/png`.
    public var contentType: String
    public var byteCount: Int
    public var width: Int?
    public var height: Int?

    public init(artworkID: String, contentType: String, byteCount: Int, width: Int? = nil, height: Int? = nil) {
        self.artworkID = artworkID
        self.contentType = contentType
        self.byteCount = byteCount
        self.width = width
        self.height = height
    }

    /// The relay design's cap on one image.
    public static let maximumByteCount = 5 * 1024 * 1024
}
