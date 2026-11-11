import CoreGraphics
import Foundation
import ImageIO
import StandByProtocol
import UniformTypeIdentifiers
@testable import CompanionCore

/// A tiny Music.app behind the `MusicScriptRunning` seam. It answers the same
/// scripts with the same text format, and its commands behave as the spike
/// verified: skipping while paused stays paused, skips reset position to 0.
final class FakeMusic: MusicScriptRunning, @unchecked Sendable {
    struct Track {
        var title: String
        var artist: String
        var album: String
        var duration: Double
        var pid: String
        var artwork: Data?
    }

    private let lock = NSLock()
    private var _running = true
    private var _state = "paused"
    private var _index = 0
    private var _position = 10.0
    private var _denied = false
    private var _nextFailure: (Int, String)?
    private var _quitDuringNextScript = false
    private var _staleReadsAfterSkip = 0
    private var _staleReadsLeft = 0
    private var _previousIndex: Int?
    private var _scripts: [MusicScript] = []
    let tracks: [Track]

    init(tracks: [Track] = FakeMusic.standardTracks, state: String = "paused") {
        self.tracks = tracks
        _state = state
    }

    static let standardTracks = [
        Track(title: "Losing My Edge", artist: "LCD Soundsystem", album: "LCD Soundsystem", duration: 473.114, pid: "542CEB17C137B39E", artwork: png(side: 800)),
        Track(title: "Idontknow", artist: "Jamie xx", album: "Idontknow", duration: 240.5, pid: "542CEB17C137B3A5", artwork: nil),
        Track(title: "Dreamland", artist: "Glass Animals", album: "Dreamland", duration: 214, pid: "542CEB17C137B3AC", artwork: png(side: 300)),
    ]

    var running: Bool {
        get { lock.withLock { _running } }
        set { lock.withLock { _running = newValue } }
    }
    var state: String {
        get { lock.withLock { _state } }
        set { lock.withLock { _state = newValue } }
    }
    var denied: Bool {
        get { lock.withLock { _denied } }
        set { lock.withLock { _denied = newValue } }
    }
    var position: Double {
        get { lock.withLock { _position } }
        set { lock.withLock { _position = newValue } }
    }
    var scripts: [MusicScript] { lock.withLock { _scripts } }
    var commands: [MusicCommand] {
        scripts.compactMap { if case .command(let c) = $0 { c } else { nil } }
    }
    var current: Track { lock.withLock { tracks[_index] } }

    func failNext(code: Int, message: String) { lock.withLock { _nextFailure = (code, message) } }
    func quitDuringNextScript() { lock.withLock { _quitDuringNextScript = true } }
    /// Music's habit seen on 11 Nov 2026: right after a skip, the artwork read
    /// returns the previous track's image under the new track's persistent ID.
    func returnPreviousArtworkAfterSkip(reads: Int) { lock.withLock { _staleReadsAfterSkip = reads } }

    /// What `MusicController` uses as its process check.
    var processCheck: @Sendable () -> Bool { { [unowned self] in self.running } }

    func run(_ script: MusicScript) -> ScriptOutput {
        lock.withLock {
            _scripts.append(script)
            if _quitDuringNextScript {
                _quitDuringNextScript = false
                _running = false
                return .failure(code: -600, message: "Application isn’t running.")
            }
            guard _running else { return .notRunning }
            if _denied { return .failure(code: -1743, message: "Not authorized to send Apple events to Music.") }
            if let (code, message) = _nextFailure {
                _nextFailure = nil
                return .failure(code: code, message: message)
            }
            switch script {
            case .snapshot:
                return .value(.text(snapshotText()))
            case .artwork:
                guard _state != "stopped" else { return .value(.text("NO_TRACK")) }
                let track = tracks[_index]
                if _staleReadsLeft > 0, let previous = _previousIndex, let stale = tracks[previous].artwork {
                    _staleReadsLeft -= 1
                    return .value(.list([.text(track.pid), .data(stale, type: "PNGf")]))
                }
                guard let art = track.artwork else { return .value(.list([.text(track.pid)])) }
                return .value(.list([.text(track.pid), .data(art, type: "PNGf")]))
            case .command(let command):
                apply(command)
                return .value(.text("ok"))
            }
        }
    }

    private func snapshotText() -> String {
        guard _state != "stopped" else {
            return ["stopped", "0", "", "", "", "", "0", "", "0", "", "0"].joined(separator: SnapshotParser.separator)
        }
        let t = tracks[_index]
        return [_state, String(_position), t.title, t.artist, t.album, "", String(t.duration), t.pid, "86657", "URL track",
                t.artwork == nil ? "0" : "1"].joined(separator: SnapshotParser.separator)
    }

    private func apply(_ command: MusicCommand) {
        switch command {
        case .play: if _state != "stopped" { _state = "playing" }
        case .pause: if _state == "playing" { _state = "paused" }
        case .playPause: _state = _state == "playing" ? "paused" : "playing"
        case .next:
            _previousIndex = _index
            _staleReadsLeft = _staleReadsAfterSkip
            _index = (_index + 1) % tracks.count
            _position = 0
        case .previous:
            _previousIndex = _index
            _staleReadsLeft = _staleReadsAfterSkip
            _index = (_index + tracks.count - 1) % tracks.count
            _position = 0
        }
    }

    /// A solid-colour PNG, encoded by ImageIO like Music's own artwork.
    static func png(side: Int) -> Data {
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }
}
