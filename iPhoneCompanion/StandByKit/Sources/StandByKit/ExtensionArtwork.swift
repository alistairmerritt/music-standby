import CoreGraphics
import Foundation
import ImageIO

/// The Now Playing extension's artwork, as one small decoded image per song.
///
/// iOS holds the extension to about 6 MB and killed it at 6,129 KB just as
/// it handed over a song's artwork (16 November 2026): given the JPEG's
/// bytes, the system decoded a 600-pixel image (about 1.4 MB) in the
/// extension once per size it asked for (1200 and 903 pixels), and the
/// previous song's were still held, so the extension sat at 5.4 MB before
/// the new song's art even arrived. Here the image is decoded once, here, at
/// `maximumPixelSize`, and every request for that song gets the same one;
/// only the current song's is kept.
public actor ExtensionArtwork {
    /// About 0.9 MB decoded. The system asks for up to 1200 pixels for StandBy.
    public static let maximumPixelSize = 480

    public static let shared = ExtensionArtwork()

    private var current: (id: String, image: CGImage)?
    private var decoding: (id: String, task: Task<CGImage, any Error>)?

    public init() {}

    /// The song's image: decoded once from `load`'s bytes, then the same
    /// image for every request until another song's is asked for.
    public func image(id: String, load: @escaping @Sendable () async throws -> Data) async throws -> CGImage {
        if let current, current.id == id { return current.image }
        if let decoding, decoding.id == id { return try await decoding.task.value }
        // Another song's: let the old image go before decoding the new one.
        current = nil
        let task = Task {
            guard let image = Self.downsample(try await load(), to: Self.maximumPixelSize) else {
                throw TransportError.artworkUnavailable
            }
            return image
        }
        decoding = (id, task)
        defer { if decoding?.id == id { decoding = nil } }
        let image = try await task.value
        current = (id, image)
        return image
    }

    /// Decodes straight to at most `size` pixels on the long side, without
    /// a full-size decode first.
    public static func downsample(_ data: Data, to size: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: size,
        ] as CFDictionary)
    }
}
