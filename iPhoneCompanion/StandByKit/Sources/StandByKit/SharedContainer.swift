import CryptoKit
import Foundation

public enum AppGroup {
    public static let identifier = "group.com.alistairmerritt.MusicStandBy"
    public static let commandSignal = "com.alistairmerritt.MusicStandBy.command"
}

/// Files shared between the app and the extension, which run as separate processes.
public struct SharedContainer: Sendable {
    public let directory: URL
    /// False when the App Group entitlement is missing and files aren't actually shared.
    public let isShared: Bool

    public init(directory: URL, isShared: Bool = true) {
        self.directory = directory
        self.isShared = isShared
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public static func appGroup() -> SharedContainer {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier) {
            return SharedContainer(directory: url.appending(path: "StandBy", directoryHint: .isDirectory))
        }
        return SharedContainer(directory: FileManager.default.temporaryDirectory.appending(path: "StandBy", directoryHint: .isDirectory), isShared: false)
    }

    func file(_ name: String) -> URL {
        directory.appending(path: name, directoryHint: .notDirectory)
    }
}

public struct CommandRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var kind: CommandKind
    public var sessionID: String
    public var receivedAt: Date

    public init(id: UUID = UUID(), kind: CommandKind, sessionID: String, receivedAt: Date) {
        self.id = id
        self.kind = kind
        self.sessionID = sessionID
        self.receivedAt = receivedAt
    }
}

/// Commands the extension received from the system, newest last.
public struct CommandLog: Sendable {
    private let url: URL
    private let limit: Int

    public init(container: SharedContainer, limit: Int = 50) {
        url = container.file("commands.json")
        self.limit = limit
    }

    public func all() -> [CommandRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([CommandRecord].self, from: data)) ?? []
    }

    public func append(_ record: CommandRecord) throws {
        let records = Array((all() + [record]).suffix(limit))
        try JSONEncoder().encode(records).write(to: url, options: .atomic)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}

public struct ArtworkStore: Sendable {
    private let container: SharedContainer
    private let fetcher: (any ArtworkFetching)?

    /// With no fetcher, only cached and generated artwork is available.
    public init(container: SharedContainer, fetcher: (any ArtworkFetching)? = nil) {
        self.container = container
        self.fetcher = fetcher
    }

    private func url(for id: String) -> URL {
        var safe = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "artwork"
        // A long id would overflow the 255-byte filename limit and the write would fail.
        if safe.utf8.count > 200 {
            safe = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        return container.file("art-\(safe)")
    }

    public func save(_ data: Data, id: String) throws {
        try data.write(to: url(for: id), options: .atomic)
    }

    public func load(id: String) -> Data? {
        try? Data(contentsOf: url(for: id))
    }

    /// Cached file, then generated placeholder art, then the relay. Without a
    /// fetcher a URL is ignored: there is no trusted host to allow it against.
    public func resolve(id: String, remoteURL: URL?) async throws -> Data {
        if let cached = load(id: id) { return cached }
        if MockArtwork.isMockID(id), let generated = MockArtwork.png(id: id) { return generated }
        guard let fetcher else { throw TransportError.artworkUnavailable }
        let data: Data
        if let remoteURL {
            data = try await fetcher.fetch(url: remoteURL)
        } else if ArtworkID.isValid(id) {
            data = try await fetcher.fetch(id: id)
        } else {
            throw TransportError.artworkUnavailable
        }
        try? save(data, id: id)
        return data
    }
}

public final class CrossProcessSignal: @unchecked Sendable {
    private let name: String
    private let handler: @Sendable () -> Void

    public init(name: String, handler: @escaping @Sendable () -> Void) {
        self.name = name
        self.handler = handler
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                Unmanaged<CrossProcessSignal>.fromOpaque(observer).takeUnretainedValue().handler()
            },
            name as CFString,
            nil,
            .deliverImmediately
        )
    }

    deinit {
        CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(), CFNotificationName(name as CFString), nil)
    }

    public static func post(_ name: String) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString), nil, nil, true)
    }
}
