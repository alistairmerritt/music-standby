import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import StandByKit

func encodedImage(_ type: UTType, width: Int = 32, height: Int = 32) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return output as Data
}

private actor FakeFetcher: ArtworkFetching {
    private(set) var urls: [URL] = []
    private(set) var ids: [String] = []
    let result: Data
    init(result: Data) { self.result = result }
    func fetch(url: URL) -> Data { urls.append(url); return result }
    func fetch(id: String) -> Data { ids.append(id); return result }
}

private func container() -> SharedContainer {
    SharedContainer(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory))
}

@Suite struct ArtworkPolicyTests {
    let policy = ArtworkPolicy()
    let host = "relay.example.com"

    @Test func acceptsHTTPSOnTheRelayHost() throws {
        try policy.validate(url: URL(string: "https://relay.example.com/v1/artwork/abc")!, allowedHost: host)
        try policy.validate(url: URL(string: "https://RELAY.example.com:443/v1/artwork/abc")!, allowedHost: host)
    }

    @Test(arguments: [
        "http://relay.example.com/a",            // not HTTPS
        "https://evil.example.com/a",            // another host
        "https://relay.example.com.evil.net/a",  // a suffix trick
        "https://relay.example.com:8443/a",      // another port
        "https://user@relay.example.com/a",      // embedded credentials
        "file:///etc/passwd",
    ])
    func rejectsUntrustedURLs(raw: String) {
        #expect(throws: TransportError.artworkUnavailable) {
            try policy.validate(url: URL(string: raw)!, allowedHost: host)
        }
    }

    @Test func rejectsEveryURLWithNoRelayConfigured() {
        #expect(throws: TransportError.artworkUnavailable) {
            try policy.validate(url: URL(string: "https://relay.example.com/a")!, allowedHost: nil)
        }
    }

    @Test func acceptsValidPNGAndJPEG() throws {
        #expect(try policy.validate(data: encodedImage(.png), contentType: "image/png") == .png)
        #expect(try policy.validate(data: encodedImage(.jpeg), contentType: "image/jpeg; charset=binary") == .jpeg)
    }

    @Test func decidesFormatFromTheBytesNotTheHeader() throws {
        #expect(try policy.validate(data: encodedImage(.png), contentType: "image/jpeg") == .png)
    }

    @Test func rejectsANonImageContentType() {
        #expect(throws: TransportError.artworkUnavailable) {
            try policy.validate(data: encodedImage(.png), contentType: "text/html")
        }
    }

    @Test func rejectsBytesThatAreNotAnImage() {
        #expect(throws: TransportError.artworkUnavailable) {
            try policy.validate(data: Data("<html>".utf8), contentType: "image/png")
        }
    }

    @Test func rejectsAHeaderWithNothingBehindIt() {
        #expect(throws: TransportError.artworkUnavailable) {
            try policy.validate(data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]), contentType: nil)
        }
    }

    @Test func rejectsEmptyData() {
        #expect(throws: TransportError.artworkUnavailable) { try policy.validate(data: Data(), contentType: nil) }
    }

    @Test func rejectsOversizedData() {
        let small = ArtworkPolicy(maximumByteCount: 8)
        #expect(throws: TransportError.artworkUnavailable) { try small.validate(data: encodedImage(.png), contentType: nil) }
    }

    @Test func rejectsOversizedDimensions() {
        let small = ArtworkPolicy(maximumPixelDimension: 16)
        #expect(throws: TransportError.artworkUnavailable) { try small.validate(data: encodedImage(.png), contentType: nil) }
    }
}

@Suite struct ArtworkStoreTests {
    let hashID = String(repeating: "a", count: 64)

    @Test func fetchesByIDFromTheRelayAndCaches() async throws {
        let image = encodedImage(.jpeg)
        let fetcher = FakeFetcher(result: image)
        let store = ArtworkStore(container: container(), fetcher: fetcher)
        #expect(try await store.resolve(id: hashID, remoteURL: nil) == image)
        #expect(try await store.resolve(id: hashID, remoteURL: nil) == image)
        #expect(await fetcher.ids == [hashID], "the second read comes from the cache")
    }

    @Test func prefersAURLFromThePushWhenThereIsOne() async throws {
        let url = URL(string: "https://relay.example.com/v1/artwork/x")!
        let fetcher = FakeFetcher(result: encodedImage(.png))
        let store = ArtworkStore(container: container(), fetcher: fetcher)
        _ = try await store.resolve(id: hashID, remoteURL: url)
        #expect(await fetcher.urls == [url])
        #expect(await fetcher.ids.isEmpty)
    }

    @Test func withoutAFetcherAURLIsNeverFollowed() async {
        let store = ArtworkStore(container: container())
        await #expect(throws: TransportError.artworkUnavailable) {
            _ = try await store.resolve(id: hashID, remoteURL: URL(string: "https://example.com/a.png"))
        }
    }

    @Test func mockIDsNeverTouchTheNetwork() async throws {
        let fetcher = FakeFetcher(result: Data())
        let store = ArtworkStore(container: container(), fetcher: fetcher)
        #expect(MockArtwork.decode(try await store.resolve(id: "mock-art-2", remoteURL: nil)) != nil)
        #expect(await fetcher.ids.isEmpty)
    }

    @Test func aMalformedIDIsNotSentToTheRelay() async {
        let fetcher = FakeFetcher(result: Data())
        let store = ArtworkStore(container: container(), fetcher: fetcher)
        await #expect(throws: TransportError.artworkUnavailable) {
            _ = try await store.resolve(id: "../../etc/passwd", remoteURL: nil)
        }
        #expect(await fetcher.ids.isEmpty)
    }

    @Test func aVeryLongIDStillCaches() throws {
        let store = ArtworkStore(container: container())
        let long = String(repeating: "/", count: 400)
        try store.save(Data([1]), id: long)
        #expect(store.load(id: long) == Data([1]))
    }

    /// The route real album art takes: a cached file straight back as bytes.
    @Test func generatedPlaceholderIsStillAValidImage() throws {
        let image = try #require(MockArtwork.image(id: "mock-art-1", pixelSize: 64))
        #expect(image.width == 64)
    }
}
