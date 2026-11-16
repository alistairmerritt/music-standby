import Foundation

/// Invented songs, for development and for the demo App Review sees.
public struct MockLibrary: Sendable {
    public let tracks: [TrackMetadata]

    public init(tracks: [TrackMetadata]) {
        precondition(!tracks.isEmpty)
        self.tracks = tracks
    }

    /// The website's six invented records, with their covers (16 November 2026).
    public static let standard = MockLibrary(tracks: [
        TrackMetadata(id: "mock-1", title: "Low Sun", artist: "Hollow Coast", album: "Breakwater", duration: 214, artworkID: "mock-art-low-sun"),
        TrackMetadata(id: "mock-2", title: "Small Hours", artist: "Fen Lights", album: "Lit Windows", duration: 252, artworkID: "mock-art-small-hours"),
        TrackMetadata(id: "mock-3", title: "Overcast, Brightening", artist: "Juniper Hall", album: "Weather for Walking", duration: 231, artworkID: "mock-art-overcast"),
        TrackMetadata(id: "mock-4", title: "Ticket Hall", artist: "Polly Atlas", album: "Concourse", duration: 178, artworkID: "mock-art-ticket-hall"),
        TrackMetadata(id: "mock-5", title: "Tidewater", artist: "Brennan & Hale", album: "Estuary", duration: 306, artworkID: "mock-art-tidewater"),
        TrackMetadata(id: "mock-6", title: "Allotment", artist: "The Small Holdings", album: "Seed Catalogue", duration: 197, artworkID: "mock-art-allotment"),
    ])

    public func trackIndex(id: String) -> Int? {
        tracks.firstIndex { $0.id == id }
    }

    public func index(after index: Int) -> Int {
        (index + 1) % tracks.count
    }

    public func index(before index: Int) -> Int {
        (index + tracks.count - 1) % tracks.count
    }

    /// Applies a command to attributes inside the extension, so a tap shows a
    /// result immediately. The revision is left alone on purpose: the next
    /// authoritative update from the app or a push always wins.
    public func applying(_ kind: CommandKind, to attributes: MacPlaybackAttributes, at date: Date) -> MacPlaybackAttributes {
        applying(RemoteCommand(kind: kind, issuedAt: date), to: attributes, at: date)
    }

    /// The mock Mac's guess at the result of a command. An output change shows
    /// nothing here: outputs live on the transport, not in the attributes.
    public func applying(_ command: RemoteCommand, to attributes: MacPlaybackAttributes, at date: Date) -> MacPlaybackAttributes {
        var result = attributes
        switch command.kind {
        case .play, .pause:
            result.elapsedTime = attributes.elapsed(at: date)
            result.timestamp = date
            result.isPlaying = command.kind == .play
        case .next, .previous:
            guard let id = attributes.track?.id, let current = trackIndex(id: id) else { return attributes }
            let target = tracks[command.kind == .next ? index(after: current) : index(before: current)]
            result.track = SessionTrack(id: target.id, title: target.title, artist: target.artist, album: target.album, duration: target.duration, artworkID: target.artworkID)
            result.elapsedTime = 0
            result.timestamp = date
        case .seek:
            guard let position = command.position else { return attributes }
            let duration = attributes.track?.duration ?? 0
            result.elapsedTime = max(0, duration > 0 ? min(position, duration) : position)
            result.timestamp = date
        case .setVolume:
            guard let level = command.level else { return attributes }
            result.volume = min(1, max(0, level))
        case .selectOutput, .playStation:
            break
        }
        return result
    }
}
