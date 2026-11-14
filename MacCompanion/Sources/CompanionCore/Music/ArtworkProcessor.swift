import Foundation
import ImageIO
import StandByProtocol
import UniformTypeIdentifiers

/// Album art ready to serve: the id of Music's original bytes, and a smaller
/// JPEG to upload. Music hands over 800 × 800 PNGs of ~376 KB (spike).
public struct ProcessedArtwork: Equatable, Sendable {
    /// `ArtworkID` of the original bytes.
    public var artworkID: String
    public var sourceFormat: String
    public var sourceByteCount: Int
    /// The bytes served for `artworkID`.
    public var image: Data
    public var descriptor: ArtworkDescriptor
}

public enum ArtworkProcessor {
    public static let maximumPixelSize = 600
    public static let jpegQuality = 0.85

    /// Nil if ImageIO cannot read the bytes.
    public static func process(_ source: Data, maximumPixelSize: Int = maximumPixelSize) -> ProcessedArtwork? {
        let id = ArtworkID.make(sourceBytes: source)
        guard let imageSource = CGImageSourceCreateWithData(source as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
              ] as CFDictionary)
        else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, thumbnail, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }

        let jpeg = output as Data
        return ProcessedArtwork(
            artworkID: id, sourceFormat: format(of: source), sourceByteCount: source.count, image: jpeg,
            descriptor: ArtworkDescriptor(artworkID: id, contentType: "image/jpeg", byteCount: jpeg.count,
                                          width: thumbnail.width, height: thumbnail.height))
    }

    /// From the magic number, as the prototype did.
    public static func format(of bytes: Data) -> String {
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpeg" }
        return "unknown"
    }
}
