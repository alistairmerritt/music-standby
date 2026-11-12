import AppIntents
import StandByKit

/// The Mac for a Shortcuts action: the pairing's credential, straight to the
/// relay. The app needn't be running and isn't opened.
@MainActor
enum ShortcutRemote {
    /// Runs `body` against the Mac. Errors are worded for Shortcuts and Siri.
    static func run<T>(_ body: (MacRemote) async throws -> T) async throws -> T {
        do {
            return try await body(try MacRemote.paired(credentials: KeychainCredentialStore()))
        } catch let error as ShortcutError {
            throw error
        } catch {
            throw ShortcutError(error)
        }
    }
}

/// What Shortcuts or Siri shows when an action fails.
struct ShortcutError: Error, CustomLocalizedStringResourceConvertible {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    init(_ error: any Error) {
        switch error {
        case TransportError.notPaired:
            message = "Second Chair isn’t paired with a Mac. Open Second Chair to pair."
        case TransportError.notConnected:
            message = "Your Mac isn’t connected. Check that it’s awake and Second Chair is open on it."
        case TransportError.commandRejected(.noSession):
            message = "There’s nothing to control on your Mac yet. Play something in Music there first."
        case TransportError.macUnreachable:
            message = "Your Mac didn’t answer. Try again."
        case let error as LocalizedError:
            message = error.errorDescription ?? error.localizedDescription
        default:
            message = error.localizedDescription
        }
    }

    var localizedStringResource: LocalizedStringResource { "\(message)" }
}
