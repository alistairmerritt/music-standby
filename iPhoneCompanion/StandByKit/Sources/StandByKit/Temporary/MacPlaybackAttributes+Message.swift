import Foundation

extension MacPlaybackAttributes {
    /// The only bridge from the temporary wire models to the attributes type.
    public init(mac: PairedMac, message: PlaybackMessage) {
        self.init(
            id: "mac-\(mac.id)",
            macName: mac.name,
            revision: message.revision,
            isPlaying: message.isPlaying,
            elapsedTime: message.elapsedTime,
            timestamp: message.capturedAt,
            track: message.track.map {
                SessionTrack(id: $0.id, title: $0.title, artist: $0.artist, album: $0.album, duration: $0.duration, artworkID: $0.artworkID)
            },
            canGoNext: message.canGoNext,
            canGoPrevious: message.canGoPrevious
        )
    }
}
