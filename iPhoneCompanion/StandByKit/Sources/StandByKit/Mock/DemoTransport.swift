import Foundation
import os

/// The demo: a simulated Mac playing invented songs, so App Review, and
/// anyone without the Mac app yet, can see the Lock Screen player work. It's
/// remembered in the App Group, where the Now Playing extension reads it too
/// (16 November 2026).
public enum DemoMode {
    public static let key = "demoMode"
    public static let mac = PairedMac(id: "demo", name: "Demo Mac")

    public static func isOn(_ defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: key)
    }

    /// Whether a launch resumes the demo: only with the demo's Mac still
    /// remembered beside the flag, so a half-finished exit can't send a real
    /// pairing to the simulated Mac. A stray flag is cleared.
    public static func resumes(_ defaults: UserDefaults) -> Bool {
        guard isOn(defaults) else { return false }
        guard PairingStore(defaults: defaults).pairedMac == mac else {
            defaults.set(false, forKey: key)
            return false
        }
        return true
    }
}

/// A transport that can stand the demo's Mac in for a paired one.
public protocol DemoSwitching: PlaybackTransport {
    /// True while the simulated Mac is in use.
    var isInDemo: Bool { get }
    /// Switches to the simulated Mac and returns it, to treat as paired.
    func startDemo() async -> PairedMac
    /// Switches back. The simulated Mac is unpaired first.
    func endDemo() async
}

/// The real transport, or the demo's simulated Mac while the demo is on. The
/// app keeps one event stream: switching follows the other transport's
/// events from its current state, so the model never needs replacing.
public actor DemoCapableTransport: DemoSwitching {
    private let real: any PlaybackTransport
    private let demo: any PlaybackTransport
    /// Read without the actor too, for `issuesSessionIDs`.
    private let isDemo: OSAllocatedUnfairLock<Bool>
    private var continuation: AsyncStream<TransportEvent>.Continuation?
    private var forwarding: Task<Void, Never>?

    public init(real: any PlaybackTransport, demo: any PlaybackTransport = MockTransport(mac: DemoMode.mac), startsInDemo: Bool) {
        self.real = real
        self.demo = demo
        isDemo = OSAllocatedUnfairLock(initialState: startsInDemo)
    }

    public nonisolated var isInDemo: Bool { isDemo.withLock { $0 } }

    public nonisolated var issuesSessionIDs: Bool {
        isInDemo ? demo.issuesSessionIDs : real.issuesSessionIDs
    }

    private var current: any PlaybackTransport {
        isInDemo ? demo : real
    }

    public func subscribe() async -> AsyncStream<TransportEvent> {
        continuation?.finish()
        let (stream, continuation) = AsyncStream.makeStream(of: TransportEvent.self, bufferingPolicy: .bufferingNewest(32))
        self.continuation = continuation
        await follow(current)
        return stream
    }

    /// Passes on one transport's events, starting with its current state.
    private func follow(_ transport: any PlaybackTransport) async {
        forwarding?.cancel()
        forwarding = nil
        guard let continuation else { return }
        let events = await transport.subscribe()
        forwarding = Task {
            for await event in events {
                continuation.yield(event)
            }
        }
    }

    public func startDemo() async -> PairedMac {
        if !isInDemo {
            isDemo.withLock { $0 = true }
            await follow(demo)
        }
        return DemoMode.mac
    }

    public func endDemo() async {
        guard isInDemo else { return }
        await demo.unpair()
        isDemo.withLock { $0 = false }
        await follow(real)
    }

    public func connect() async { await current.connect() }
    public func reconnect() async { await current.reconnect() }
    public func disconnect() async { await current.disconnect() }
    public func suspend() async { await current.suspend() }
    public func unpair() async { await current.unpair() }
    public func refreshState() async { await current.refreshState() }

    public func pair(code: PairingCode, progress: @escaping @Sendable (PairingProgress) async -> Void) async throws -> PairedMac {
        try await current.pair(code: code, progress: progress)
    }

    public func send(_ command: RemoteCommand) async throws -> CommandAck {
        try await current.send(command)
    }

    public func artwork(id: String) async throws -> Data {
        try await current.artwork(id: id)
    }
}
