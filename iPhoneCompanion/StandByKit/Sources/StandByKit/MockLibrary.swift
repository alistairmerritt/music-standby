import Foundation

/// Invented songs for exercising Now Playing before the Mac app exists.
public struct MockLibrary: Sendable {
    public let tracks: [TrackMetadata]

    public init(tracks: [TrackMetadata]) {
        precondition(!tracks.isEmpty)
        self.tracks = tracks
    }

    public static let standard = MockLibrary(tracks: [
        TrackMetadata(id: "mock-1", title: "Harbour Lights", artist: "The Paper Tigers", album: "Low Tide", duration: 214, artworkID: "mock-art-1"),
        TrackMetadata(id: "mock-2", title: "Second Glance", artist: "Mira Vale", album: "Half Light", duration: 187, artworkID: "mock-art-2"),
        TrackMetadata(id: "mock-3", title: "Northbound", artist: "Coastal Radio", album: "Signal", duration: 263, artworkID: "mock-art-3"),
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
        case .selectOutput:
            break
        }
        return result
    }
}
