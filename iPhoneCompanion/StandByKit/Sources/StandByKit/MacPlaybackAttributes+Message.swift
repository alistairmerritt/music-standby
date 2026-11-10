import Foundation

extension MacPlaybackAttributes {
    /// The only bridge from the shared wire models to the attributes type.
    /// `sessionID` is the relay's identifier when it has issued one.
    public init(mac: PairedMac, message: PlaybackMessage, sessionID: String? = nil) {
        self.init(
            id: sessionID ?? "mac-\(mac.id)",
            macName: mac.name,
            revision: message.revision,
            isPlaying: message.isPlaying,
            elapsedTime: message.elapsedTime,
            timestamp: message.capturedAt,
            track: message.track.map {
                SessionTrack(id: $0.id, title: $0.title, artist: $0.artist, album: $0.album, duration: $0.duration, artworkID: $0.artworkID.flatMap { $0.isEmpty ? nil : $0 })
            },
            canGoNext: message.canGoNext,
            canGoPrevious: message.canGoPrevious
        )
    }
}
