import Foundation
import Testing
@testable import StandByKit

/// The Continue Listening row in the Mac section. Added 16 November 2026.
@Suite struct ContinueListeningStatusTests {
    @Test func readyNeedsTheMacConnectedToMusicAndAppleMusicHere() {
        #expect(ContinueListeningStatus.assess(mac: .connected, appleMusicAccess: .allowed, canPlayCatalog: true) == .ready)
        #expect(ContinueListeningStatus.assess(mac: .connected, appleMusicAccess: .allowed, canPlayCatalog: nil) == .ready, "not known yet isn't a problem")
    }

    @Test func theMacComesFirst() {
        #expect(ContinueListeningStatus.assess(mac: .notConnected, appleMusicAccess: .denied, canPlayCatalog: false) == .setUpOnMac)
        #expect(ContinueListeningStatus.assess(mac: .forgotten, appleMusicAccess: .allowed, canPlayCatalog: true) == .reconnectOnMac)
    }

    @Test func thenThisPhone() {
        #expect(ContinueListeningStatus.assess(mac: .connected, appleMusicAccess: .notDetermined, canPlayCatalog: nil) == .allowAppleMusic(canAsk: true))
        #expect(ContinueListeningStatus.assess(mac: .connected, appleMusicAccess: .denied, canPlayCatalog: nil) == .allowAppleMusic(canAsk: false))
        #expect(ContinueListeningStatus.assess(mac: .connected, appleMusicAccess: .allowed, canPlayCatalog: false) == .needsAppleMusic)
    }

    @Test func nothingToSayWithoutWordFromTheMac() {
        #expect(ContinueListeningStatus.assess(mac: nil, appleMusicAccess: .allowed, canPlayCatalog: true) == nil)
        #expect(ContinueListeningStatus.assess(mac: "teleported", appleMusicAccess: .allowed, canPlayCatalog: true) == nil, "a value this build doesn't know")
        #expect(ContinueListeningStatus.assess(mac: nil, appleMusicAccess: .denied, canPlayCatalog: nil) == .allowAppleMusic(canAsk: false), "this phone can still say")
    }
}

@MainActor
@Suite struct MacMusicConnectionTests {
    @Test func isKeptFromTheNewestStateEvenWithoutASession() async {
        let h = Harness(relayNamesSessions: true)
        let task = await h.run()
        defer { task.cancel() }
        await h.connected()
        var newer = message(revision: 5, state: .paused)
        newer.musicConnection = .connected
        await h.transport.emit(.playback(newer))
        await eventually("the connection seen") { h.model.macMusicConnection == .connected }
        #expect(h.model.attributes == nil, "no session, so nothing in Now Playing")
        var older = message(revision: 4, state: .paused)
        older.musicConnection = .notConnected
        await h.transport.emit(.playback(older))
        var forgotten = message(revision: 6, state: .paused)
        forgotten.musicConnection = .forgotten
        await h.transport.emit(.playback(forgotten))
        await eventually("the newest wins") { h.model.macMusicConnection == .forgotten }
    }
}
