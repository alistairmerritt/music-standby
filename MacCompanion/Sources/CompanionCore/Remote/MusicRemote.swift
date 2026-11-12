import Foundation
import Network
import os
import StandByProtocol

/// The companion paired with Music as a remote, the way Apple's iTunes Remote
/// app pairs: the GUID the companion gave Music, and the Bonjour name of
/// Music's `_touch-able._tcp` service that paired with it.
public struct MusicRemotePairing: Codable, Equatable, Sendable {
    public var guid: String
    public var serviceName: String

    public init(guid: String, serviceName: String) {
        self.guid = guid
        self.serviceName = serviceName
    }
}

/// What Music's remote protocol adds to AppleScript: the current song's Apple
/// Music catalogue ID, and Up Next.
public struct RemoteQueue: Equatable, Sendable {
    public var catalogID: String?
    public var upNext: [QueuedTrack]

    public init(catalogID: String?, upNext: [QueuedTrack]) {
        self.catalogID = catalogID
        self.upNext = upNext
    }
}

public protocol MusicRemoteReading: Sendable {
    /// The current song's catalogue ID (by its persistent ID), and Up Next.
    /// Nil when Music can't be reached or has forgotten the pairing.
    func queue(current track: MusicTrack?) async -> RemoteQueue?
    /// Music's own now-playing artwork, when Music is still playing this
    /// track. Nil when it isn't, has none, or can't be reached.
    func artwork(for track: MusicTrack) async -> Data?
}

extension MusicRemoteReading {
    public func artwork(for track: MusicTrack) async -> Data? { nil }
}

public enum MusicRemoteStatus: Equatable, Sendable {
    case unknown, connected, unreachable
    /// Music answered 503 to the pairing: "Forget All Remotes" was used, or
    /// Music's library changed. Pair again.
    case unpaired
}

/// HTTP to Music on this Mac. A seam for tests.
public protocol LocalHTTP: Sendable {
    func get(port: Int, path: String) async throws -> (status: Int, body: Data)
}

public struct URLSessionLocalHTTP: LocalHTTP {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.httpAdditionalHeaders = ["Viewer-Only-Client": "1", "User-Agent": "Remote/1021"]
        session = URLSession(configuration: configuration)
    }

    public func get(port: Int, path: String) async throws -> (status: Int, body: Data) {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { throw URLError(.badURL) }
        let (data, response) = try await session.data(from: url)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

/// Reads Music's Up Next and catalogue IDs over DACP. Only reads: it never
/// plays, skips or changes volume. Verified against Music on macOS 27 on
/// 12 November 2026 with a test remote: every one of 12,679 library songs
/// carried a catalogue ID (`aeSI`, `com.apple.itunes.itms-songid`) that
/// Apple's lookup confirmed, and `mper` equals AppleScript's persistent ID.
public actor MusicRemoteClient: MusicRemoteReading {
    public static let libraryRefreshInterval: TimeInterval = 60

    private let pairing: MusicRemotePairing
    private let http: any LocalHTTP
    private let locate: @Sendable (String) async -> Int?
    private let now: @Sendable () -> Date
    private var port: Int?
    private var session: UInt64?
    private var catalogByPersistentID: [String: String] = [:]
    private var catalogByItemID: [UInt64: String] = [:]
    private var libraryReadAt: Date?
    public private(set) var status: MusicRemoteStatus = .unknown

    public init(pairing: MusicRemotePairing, http: any LocalHTTP = URLSessionLocalHTTP(),
                locate: @escaping @Sendable (String) async -> Int? = { await MusicRemoteLocator.port(serviceName: $0) },
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.pairing = pairing
        self.http = http
        self.locate = locate
        self.now = now
    }

    private enum Failure: Error { case unpaired, unreachable }

    public func queue(current track: MusicTrack?) async -> RemoteQueue? {
        let persistentID = track?.persistentID?.uppercased()
        do {
            if catalogByItemID.isEmpty || (persistentID.map { catalogByPersistentID[$0] == nil } ?? false) {
                try await refreshLibrary()
            }
            let body = try await get("/ctrl-int/1/playqueue-contents?span=\(PlaybackMessage.upNextLimit)")
            status = .connected
            return RemoteQueue(catalogID: persistentID.flatMap { catalogByPersistentID[$0] }, upNext: upNext(from: body))
        } catch Failure.unpaired {
            status = .unpaired
        } catch {
            status = .unreachable
            port = nil
            session = nil
        }
        return nil
    }

    /// `nowplayingartwork` at 600 px, after checking Music's now-playing title
    /// and artist are the track's, so a skip in between can't hand over the
    /// wrong cover. Measured 12 Nov 2026 on a song streamed from Apple Music,
    /// not in the library: AppleScript had no artwork, this had Music's 600 px
    /// cover (a 488 KB PNG) in 97 ms.
    public func artwork(for track: MusicTrack) async -> Data? {
        do {
            let status = DMAPNode.parse(try await get("/ctrl-int/1/playstatusupdate?revision-number=1"))
            func same(_ tag: String, _ value: String) -> Bool {
                status.first(tag).map { $0.string.compare(value, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame } ?? false
            }
            guard same("cann", track.title), same("cana", track.artist) else { return nil }
            let image = try await get("/ctrl-int/1/nowplayingartwork?mw=600&mh=600")
            return image.isEmpty ? nil : image
        } catch {
            return nil
        }
    }

    /// Persistent ID → catalogue ID for the whole library: about 0.3 s for
    /// 12,679 songs. At most once a minute, so a song Music doesn't know
    /// (the radio, say) doesn't cost a library read each time.
    private func refreshLibrary() async throws {
        if let readAt = libraryReadAt, now().timeIntervalSince(readAt) < Self.libraryRefreshInterval { return }
        libraryReadAt = now()
        let databases = DMAPNode.parse(try await get("/databases"))
        guard let database = databases.first("mlcl")?.first("miid")?.integer else { throw Failure.unreachable }
        let meta = "dmap.itemid,dmap.persistentid,com.apple.itunes.itms-songid"
        let items = DMAPNode.parse(try await get("/databases/\(database)/items?type=music&meta=\(meta)"))
        var byPersistentID: [String: String] = [:]
        var byItemID: [UInt64: String] = [:]
        for item in items.first("mlcl")?.all("mlit") ?? [] {
            guard let catalog = item.all("aeSI").first?.integer, catalog != 0 else { continue }
            if let persistent = item.all("mper").first?.integer {
                byPersistentID[String(format: "%016llX", persistent)] = String(catalog)
            }
            if let id = item.all("miid").first?.integer { byItemID[id] = String(catalog) }
        }
        catalogByPersistentID = byPersistentID
        catalogByItemID = byItemID
    }

    /// Up Next from `playqueue-contents`: its `mlit`s that name a song (a
    /// `ceQs` of database, container, container item and item, 4 bytes each).
    func upNext(from body: Data) -> [QueuedTrack] {
        let list = DMAPNode.parse(body).first("mlcl")?.all("mlit") ?? []
        return list.compactMap { entry -> QueuedTrack? in
            guard let spec = entry.all("ceQs").first?.value, spec.count == 16 else { return nil }
            let itemID = spec.suffix(4).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            return QueuedTrack(catalogID: catalogByItemID[itemID],
                               title: entry.all("ceQn").first?.string ?? "",
                               artist: entry.all("ceQr").first?.string ?? "",
                               album: entry.all("ceQa").first?.string,
                               duration: Double(entry.all("astm").first?.integer ?? 0) / 1000)
        }
        .prefix(PlaybackMessage.upNextLimit).map { $0 }
    }

    /// A GET with the session, logging in first, and once again if Music
    /// has let the session go.
    private func get(_ path: String) async throws -> Data {
        for attempt in 0..<2 {
            let session = try await login()
            let separator = path.contains("?") ? "&" : "?"
            let (status, body) = try await raw("\(path)\(separator)session-id=\(session)")
            if status == 200 { return body }
            if status == 401 || status == 403, attempt == 0 { self.session = nil; continue }
            throw Failure.unreachable
        }
        throw Failure.unreachable
    }

    private func login() async throws -> UInt64 {
        if let session { return session }
        let (status, body) = try await raw("/login?pairing-guid=0x\(pairing.guid)")
        if status == 503 { throw Failure.unpaired }
        guard status == 200, let id = DMAPNode.parse(body).first("mlid")?.integer else { throw Failure.unreachable }
        session = id
        return id
    }

    private func raw(_ path: String) async throws -> (status: Int, body: Data) {
        if port == nil { port = await locate(pairing.serviceName) }
        guard let port else { throw Failure.unreachable }
        do {
            return try await http.get(port: port, path: path)
        } catch {
            self.port = nil
            throw Failure.unreachable
        }
    }
}

/// Finds Music's DACP port. Music advertises `_touch-able._tcp` once it has a
/// paired remote; the port changes when Music restarts.
public enum MusicRemoteLocator {
    public static func port(serviceName: String, timeout: Duration = .seconds(3)) async -> Int? {
        let queue = DispatchQueue(label: "MusicRemoteLocator")
        let browser = NWBrowser(for: .bonjour(type: "_touch-able._tcp", domain: "local."), using: .tcp)
        let found = OSAllocatedUnfairLock<CheckedContinuation<Int?, Never>?>(initialState: nil)
        let connection = OSAllocatedUnfairLock<NWConnection?>(initialState: nil)
        let finish: @Sendable (Int?) -> Void = { port in
            let waiting = found.withLock { continuation -> CheckedContinuation<Int?, Never>? in
                defer { continuation = nil }
                return continuation
            }
            browser.cancel()
            connection.withLock { $0?.cancel() }
            waiting?.resume(returning: port)
        }
        return await withCheckedContinuation { continuation in
            found.withLock { $0 = continuation }
            browser.browseResultsChangedHandler = { results, _ in
                guard let result = results.first(where: {
                    if case .service(let name, _, _, _) = $0.endpoint { return name == serviceName }
                    return false
                }) else { return }
                let probe = NWConnection(to: result.endpoint, using: .tcp)
                connection.withLock { $0?.cancel(); $0 = probe }
                probe.stateUpdateHandler = { state in
                    guard case .ready = state else { return }
                    if case .hostPort(_, let port)? = probe.currentPath?.remoteEndpoint { finish(Int(port.rawValue)) }
                }
                probe.start(queue: queue)
            }
            browser.start(queue: queue)
            Task {
                try? await Task.sleep(for: timeout)
                finish(nil)
            }
        }
    }
}
