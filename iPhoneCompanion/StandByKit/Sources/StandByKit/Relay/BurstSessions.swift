import Foundation

/// One URLSession for a burst of requests, then a fresh one. Requests while
/// another is in flight, or within `window` of the last one ending, share the
/// session (and over HTTP/2 one connection to the relay); after that the
/// session is let go, since iOS kills a suspended extension's sockets. Added
/// 16 November 2026 for the Now Playing extension's memory.
final class BurstSessions: @unchecked Sendable {
    /// Well inside the ~2 s after which iOS was seen to kill a kept socket.
    static let defaultWindow: TimeInterval = 1

    private let lock = NSLock()
    private let window: TimeInterval
    private let now: @Sendable () -> Date
    private let make: @Sendable () -> URLSession
    private var session: URLSession?
    private var inFlight = 0
    private var idleSince: Date?

    init(window: TimeInterval = defaultWindow, now: @escaping @Sendable () -> Date = { Date() },
         make: @escaping @Sendable () -> URLSession = { URLSession(configuration: URLSessionHTTP.configuration()) }) {
        self.window = window
        self.now = now
        self.make = make
    }

    /// The session for a request about to start. Pair with `end()`.
    func begin() -> URLSession {
        lock.withLock {
            if let session, inFlight > 0 || idleSince.map({ now().timeIntervalSince($0) < window }) == true {
                inFlight += 1
                return session
            }
            session?.finishTasksAndInvalidate()
            let fresh = make()
            session = fresh
            inFlight = 1
            idleSince = nil
            return fresh
        }
    }

    func end() {
        lock.withLock {
            inFlight = max(0, inFlight - 1)
            if inFlight == 0 { idleSince = now() }
        }
    }
}
