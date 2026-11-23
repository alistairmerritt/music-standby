import AppKit
import CompanionCore
import StandByProtocol
import SwiftUI

/// The menu bar panel: the live companion turned into a `MenuModel` for
/// `MenuLayout` (21 November 2026 redesign).
struct MenuContent: View {
    let companion: Companion
    let relay: RelayAccount?
    let musicRemote: MusicRemoteAccount
    let launchAtLogin: LaunchAtLogin

    @State private var confirmingUnpair = false
    @State private var musicJustConnected = false
    /// "Not Now" on the Continue Listening row: the gear menu still has it.
    @AppStorage("menu.continueListeningDismissed") private var continueListeningDismissed = false
    /// "Not Now" on the Launch at Login tip: the gear menu still has it.
    @AppStorage("menu.launchTipDismissed") private var launchTipDismissed = false

    var body: some View {
        MenuLayout(model: model, actions: actions) {
            if let mock = companion.transport as? MockRelayTransport {
                MockRelaySection(companion: companion, mock: mock)
            }
        }
        .task { await musicRemote.checkStatus() }
        .onAppear { launchAtLogin.refresh() }
        .onChange(of: musicRemote.state) { old, new in
            // A short confirmation once setup succeeds, then out of the way.
            guard case .pairing = old, new == .paired else { return }
            musicJustConnected = true
            Task {
                try? await Task.sleep(for: .seconds(5))
                musicJustConnected = false
            }
        }
        .onChange(of: companion.pairedPhone == nil) { _, unpaired in
            if unpaired { confirmingUnpair = false }
        }
    }

    // MARK: Model

    private var model: MenuModel {
        MenuModel(
            music: music,
            handedOver: companion.phoneHasMusic && companion.snapshot?.state != .playing,
            offersContinueFromPhone: companion.offersContinueFromPhone,
            handBack: companion.handBack,
            setup: setup,
            relayError: relay?.lastError,
            launchMessage: launchAtLogin.message,
            phase: relay == nil ? .connected : companion.connection.phase,
            failureCode: companion.connection.error.map { $0.code.rawValue },
            phonePaired: companion.pairedPhone != nil,
            hasRelay: relay != nil,
            launchAtLogin: launchAtLogin.isEnabled,
            musicLink: musicLink,
            version: Self.version
        )
    }

    private var music: MenuModel.Music {
        guard let snapshot = companion.snapshot else { return .checking }
        switch snapshot.state {
        case .notRunning: return .notRunning
        case .automationDenied: return .automationDenied
        default: break
        }
        if let track = snapshot.track {
            let message = companion.message
            return .track(MenuModel.TrackInfo(
                title: track.title, artist: track.artist, album: track.album,
                artwork: companion.artwork?.image, state: snapshot.state,
                duration: message?.track?.duration,
                elapsed: { date in message?.elapsed(at: date) ?? 0 }))
        }
        if snapshot.isMusicSlow { return .slow }
        if snapshot.state == .error { return .readError(snapshot.detail) }
        return .nothing
    }

    /// One card at a time, most urgent first.
    private var setup: MenuModel.Setup? {
        let paired = companion.pairedPhone != nil
        if confirmingUnpair, paired { return .confirmUnpair }
        if let relay {
            if let request = companion.pairRequests.first { return .pairRequest(phoneName: request.phone.name) }
            if !paired {
                if let code = relay.pairingCode { return .pairCode(code: code.code, expiresAt: code.expiresAt) }
                return .pairStart(enabled: relay.isRegistered && companion.connection.phase == .connected)
            }
        }
        switch musicRemote.state {
        case .pairing(let code): return .musicCode(code)
        case .forgottenByMusic: return .musicForgotten
        case .failed(let message): return .musicFailed(message)
        case .paired, .unpaired: break
        }
        if musicJustConnected { return .musicJustConnected }
        if paired, musicRemote.state == .unpaired, !continueListeningDismissed { return .continueListeningNotSetUp }
        if paired, !launchAtLogin.isEnabled, launchAtLogin.message == nil, !launchTipDismissed { return .launchTip }
        return nil
    }

    private var musicLink: MenuModel.MusicLink {
        switch musicRemote.state {
        case .paired: .connected
        case .unpaired: .notConnected
        case .pairing: .connecting
        case .forgottenByMusic: .forgotten
        case .failed: .failed
        }
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        return "Second Chair \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    // MARK: Actions

    private var actions: MenuActions {
        MenuActions(
            transport: { companion.perform($0) },
            continueFromPhone: { companion.continueFromPhone() },
            openMusic: {
                // Only ever on an explicit click.
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Music.app"), configuration: .init())
            },
            openPrivacySettings: {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                    NSWorkspace.shared.open(url)
                }
            },
            pairIPhone: { if let relay { Task { await relay.requestPairingCode() } } },
            allow: {
                guard let request = companion.pairRequests.first else { return }
                companion.decidePairing(request.claimID, approved: true)
                relay?.clearPairingCode()
            },
            dontAllow: {
                guard let request = companion.pairRequests.first else { return }
                companion.decidePairing(request.claimID, approved: false)
            },
            askToUnpair: { confirmingUnpair = true },
            unpair: {
                confirmingUnpair = false
                if let relay { Task { await relay.unpair() } }
            },
            cancelUnpair: { confirmingUnpair = false },
            connectToMusic: { musicRemote.startPairing() },
            cancelMusicCode: { musicRemote.cancelPairing() },
            disconnectFromMusic: { musicRemote.forget() },
            dismissContinueListening: { continueListeningDismissed = true },
            setLaunchAtLogin: { launchAtLogin.set($0) },
            dismissLaunchTip: { launchTipDismissed = true },
            quit: { NSApp.terminate(nil) }
        )
    }
}

/// Stands in for the iPhone until the relay exists. Commands go through the
/// mock relay as wire JSON, the same path a real phone command will take.
private struct MockRelaySection: View {
    let companion: Companion
    let mock: MockRelayTransport

    var body: some View {
        DisclosureGroup("Simulate iPhone") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    ForEach(CommandKind.allCases.filter { $0.requiredValue == nil }, id: \.self) { kind in
                        Button(kind.rawValue.capitalized) { Task { await mock.simulateCommand(kind) } }
                    }
                }
                .controlSize(.small)
                if let message = companion.message {
                    Text("Last state: r\(String(message.revision)) · \(message.state.rawValue)")
                }
                if let ack = companion.lastAck {
                    Text("Last ack: \(ack.accepted ? "accepted" : ack.error?.code.rawValue ?? "rejected") · r\(String(ack.revision))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
        }
    }
}
