import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The demo's album art: a bundled cover for `mock-art-<name>` when there is
/// one, otherwise a generated placeholder. No network either way.
public enum MockArtwork {
    public static func isMockID(_ id: String) -> Bool {
        id.hasPrefix("mock-art-")
    }

    /// The image to hand over for a mock artwork ID: the bundled JPEG as it
    /// is, so the Now Playing extension never decodes it, or a generated PNG.
    public static func data(id: String) -> Data? {
        cover(id: id) ?? png(id: id)
    }

    /// A cover in `Resources/DemoArtwork`, named after the ID without its prefix.
    static func cover(id: String) -> Data? {
        guard isMockID(id) else { return nil }
        let name = String(id.dropFirst("mock-art-".count))
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }),
              let url = Bundle.module.url(forResource: name, withExtension: "jpg", subdirectory: "DemoArtwork")
        else { return nil }
        return try? Data(contentsOf: url)
    }

    public static func png(id: String, pixelSize: Int = 600) -> Data? {
        image(id: id, pixelSize: pixelSize).flatMap(pngData)
    }

    public static func image(id: String, pixelSize: Int = 600) -> CGImage? {
        let palette: [(CGFloat, CGFloat, CGFloat)] = [(0.95, 0.42, 0.33), (0.25, 0.47, 0.87), (0.20, 0.68, 0.55), (0.62, 0.36, 0.82)]
        let seed = id.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        let a = palette[seed % palette.count]
        let b = palette[(seed + 1) % palette.count]
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: pixelSize, height: pixelSize, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let gradient = CGGradient(colorsSpace: space, colors: [CGColor(red: a.0, green: a.1, blue: a.2, alpha: 1), CGColor(red: b.0, green: b.1, blue: b.2, alpha: 1)] as CFArray, locations: [0, 1])
        else { return nil }
        let size = CGFloat(pixelSize)
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size, y: size), options: [])
        context.setFillColor(CGColor(gray: 1, alpha: 0.22))
        context.fillEllipse(in: CGRect(x: size * 0.25, y: size * 0.25, width: size * 0.5, height: size * 0.5))
        return context.makeImage()
    }

    private static func pngData(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    public static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
