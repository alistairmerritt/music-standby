import AppKit
import Darwin
import Foundation
import os

/// Finds Music's process without sending it anything.
///
/// `NSRunningApplication.runningApplications(withBundleIdentifier:)` alone is
/// not a reliable check. Measured on macOS 27.0.1 while Music ran: it returned
/// an empty list for 3–15 ms every 1–5 s, on and off the main thread. That
/// happened around each check-in of a short-lived process (the scrobbler's
/// `osascript`, every 1.2 s), and a read that landed in one reported Music as
/// closed. So Music's PID is looked up once, then checked by its executable
/// path with `proc_pidpath`, which the kernel answers. It is looked up again
/// only when that process has gone or the PID now names another program.
/// About 2 µs a check.
public final class MusicProcess: Sendable {
    public static let shared = MusicProcess()

    /// After a relaunch on macOS 27.0.1, Music first answered an Apple Event
    /// 3.85 s after its process was spawned, and in another an event 4.04 s
    /// after spawn was answered. One sent 0.12 s after spawn timed out at 3 s.
    public static let answerDelay: TimeInterval = 4

    private struct Known {
        var pid: pid_t
        var path: String
    }

    private let known = OSAllocatedUnfairLock<Known?>(initialState: nil)
    private let lookUp: @Sendable () -> pid_t?

    init(lookUp: @escaping @Sendable () -> pid_t? = MusicProcess.lookUpWithLaunchServices) {
        self.lookUp = lookUp
    }

    /// Music's PID, or nil when it isn't running.
    public func pid() -> pid_t? {
        known.withLock { known in
            if let current = known, Self.path(of: current.pid) == current.path { return current.pid }
            known = lookUp().flatMap { pid in Self.path(of: pid).map { Known(pid: pid, path: $0) } }
            return known?.pid
        }
    }

    /// How long ago the process was spawned, from the kernel.
    public static func age(of pid: pid_t) -> TimeInterval? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let started = TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000
        return Date().timeIntervalSince1970 - started
    }

    /// The executable's path, or nil once the process has gone.
    static func path(of pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    static func lookUpWithLaunchServices() -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: MusicController.bundleID)
            .first { !$0.isTerminated }?.processIdentifier
    }
}
