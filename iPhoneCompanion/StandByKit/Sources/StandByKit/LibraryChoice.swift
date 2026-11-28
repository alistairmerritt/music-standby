import Foundation

// Continue on Mac and an Apple Music playlist or album that isn't in the
// library (28 November 2026). The Mac can only play a playlist or album from
// the library, so keeping it going there means adding it first. Until now a
// switch decided that silently (off unless turned on); now the person is
// asked, once or every time, before anything moves. The question is asked at
// the one point in `Handover.sendBackToMac` that used to read the switch:
// before any command reaches the Mac, so the phone plays on while they decide.

/// Settings › When a playlist or album isn't in your library.
public enum LibraryPreference: String, CaseIterable, Sendable {
    /// Ask Every Time. The default for new people.
    case ask
    /// Add to Library.
    case add
    /// Play Song Station.
    case station
}

/// What the person is asked.
public struct LibraryQuestion: Equatable, Sendable {
    public enum Kind: Sendable { case playlist, album }
    public var kind: Kind
    /// The playlist's name or the album's title, as Apple Music shows it.
    public var name: String
    /// Adding it was tried just now and failed: offer to try again instead.
    public var addFailed: Bool

    public init(kind: Kind, name: String, addFailed: Bool = false) {
        self.kind = kind
        self.name = name
        self.addFailed = addFailed
    }
}

/// The person's answer.
public enum LibraryAnswer: Equatable, Sendable {
    /// Add & Continue (or Try Again after a failure).
    case add(remember: Bool)
    /// Play Song Station.
    case station(remember: Bool)
    /// Cancel, or the dialog closed without a choice: nothing moves, nothing is added.
    case cancel
    /// Nobody here can answer, but the Mac that asked for the music can: it
    /// shows the dialog and asks again with the answer.
    case askTheMac
}

/// Shows the question and waits for the answer. Nil where nobody can be
/// asked (Shortcuts, widgets, a Mac that can't show the dialog): there, a
/// setting of Ask Every Time plays the song's station and adds nothing.
public typealias LibraryAsker = @MainActor (LibraryQuestion) async -> LibraryAnswer

extension AppleMusicSource {
    /// Which playlist or album an answer was for, so it isn't used for another.
    var libraryKey: String {
        switch self {
        case .album(let place, let id): "album:\(id):\(place.title)"
        case .playlist(let place): "playlist:\(place.cloudID ?? ""):\(place.name)"
        case .station(let place): "station:\(place)"
        }
    }
}

extension HandBackRequest {
    /// The Mac's answer to the question, for `Handover.sendBackToMac`. Nil
    /// when the request carries none (an older Mac or relay, or the Mac's
    /// Shortcuts action): nobody can be asked. The Mac's add or station
    /// answers the first question only; any other goes back to the Mac.
    @MainActor public func libraryAsker() -> LibraryAsker? {
        guard let library, [HandBackLibraryChoice.ask, .add, .station].contains(library) else { return nil }
        var answered = false
        let remember = remember == true
        return { question in
            guard !answered, !question.addFailed else { return .askTheMac }
            answered = true
            switch library {
            case .add: return .add(remember: remember)
            case .station: return .station(remember: remember)
            default: return .askTheMac
            }
        }
    }
}
