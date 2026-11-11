import Foundation
import Testing
import StandByProtocol
@testable import CompanionCore

/// End to end: fake Music ↔ Companion ↔ mock relay, through wire JSON.
@MainActor
@Suite(.serialized) struct CompanionTests {
    struct Rig {
        let companion: Companion
        let music: FakeMusic
        let relay: MockRelayTransport
        let defaults: UserDefaults
    }

    private static let device = DeviceIdentity(id: "test-mac", name: "Test Mac", kind: .mac, appVersion: "test")

    private func rig(state: String = "playing", defaults: UserDefaults? = nil, now: @escaping @Sendable () -> Date = { Date() },
                     tracks: [FakeMusic.Track] = FakeMusic.standardTracks, artworkLookup: (any CatalogArtworkLookup)? = nil) async -> Rig {
        let music = FakeMusic(tracks: tracks, state: state)
        let relay = MockRelayTransport()
        let defaults = defaults ?? UserDefaults(suiteName: "CompanionTests-\(UUID().uuidString)")!
        let companion = Companion(controller: MusicController(runner: music, isRunning: music.processCheck),
                                  transport: relay, store: CompanionStore(defaults: defaults), device: Self.device,
                                  artworkLookup: artworkLookup, now: now, isMusicLaunching: { false })
        companion.settleDelay = .zero
        companion.artworkSettle = 0
        for state in PlaybackState.allCases { companion.monitor.pollIntervals[state] = .seconds(3600) }
        companion.start()
        let ok = await eventually { await relay.sent.contains { if case .state = $0 { true } else { false } } }
        if !ok {
            print("EVENTS:", companion.events.map(\.text))
            print("SENT:", await relay.sentJSON)
            print("SCRIPTS:", music.scripts)
        }
        return Rig(companion: companion, music: music, relay: relay, defaults: defaults)
    }

    @discardableResult
    private func eventually(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<300 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("condition not met within 3 s")
        return false
    }

    private func states(_ relay: MockRelayTransport) async -> [PlaybackMessage] {
        await relay.sent.compactMap { if case .state(let m) = $0 { m } else { nil } }
    }

    @Test func connectingSaysHelloThenSendsState() async throws {
        let r = await rig()
        let sent = await r.relay.sent
        guard case .hello(let hello) = sent.first else { Issue.record("first frame was not hello"); return }
        #expect(hello.protocolVersion == StandByWire.version)
        #expect(hello.device == Self.device)
        let state = try #require(await states(r.relay).last)
        #expect(state.state == .playing)
        #expect(state.track?.title == "Losing My Edge")
        #expect(state.listeningSessionID != nil)
        #expect(r.companion.connection.phase == .connected)
    }

    @Test func pauseFromThePhone() async throws {
        let r = await rig()
        let id = await r.relay.simulateCommand(.pause)
        await eventually { await r.relay.ack(for: id) != nil }
        let ack = try #require(await r.relay.ack(for: id))
        #expect(ack.accepted)
        #expect(r.music.state == "paused")
        // The ack leaves as soon as Music takes the command; the state showing
        // the result follows it, with a later revision (PROTOCOL.md §5).
        await eventually { await states(r.relay).last?.isPlaying == false }
        let last = try #require(await states(r.relay).last)
        #expect(last.revision > ack.revision)
        let sent = await r.relay.sent
        let stateIndex = sent.lastIndex { if case .state(let m) = $0 { m.revision == last.revision } else { false } }
        let ackIndex = sent.lastIndex { if case .ack = $0 { true } else { false } }
        #expect(ackIndex! < stateIndex!)
    }

    @Test func pairRequestsWaitForTheMac() async throws {
        let r = await rig()
        let phone = DeviceIdentity(id: "p", name: "Test iPhone", kind: .iPhone)
        let request = PairRequest(claimID: "c1", phone: phone, expiresAt: Date().addingTimeInterval(300))
        await r.relay.simulate(.pairRequest(request))
        await eventually { r.companion.pairRequests == [request] }
        #expect(await !r.relay.sent.contains { if case .pairDecision = $0 { true } else { false } })
        r.companion.decidePairing("c1", approved: true)
        await eventually { await r.relay.sent.contains(.pairDecision(claimID: "c1", approved: true)) }
        #expect(r.companion.pairRequests.isEmpty)
        await r.relay.simulate(.paired(phone: phone))
        await eventually { r.companion.pairedPhone == phone }
    }

    @Test func nextChangesTrackButNotSession() async throws {
        let r = await rig()
        let before = try #require(await states(r.relay).last)
        let id = await r.relay.simulateCommand(.next)
        await eventually { await r.relay.ack(for: id) != nil }
        let after = try #require(await states(r.relay).last)
        #expect(after.track?.id.hasPrefix("pid:542CEB17C137B3A5-") == true)
        #expect(after.listeningSessionID == before.listeningSessionID)
        #expect(after.elapsedTime == 0)
        #expect(after.revision > before.revision)
    }

    @Test func repeatedCommandIDActsOnce() async throws {
        let r = await rig(state: "paused")
        let id = UUID()
        await r.relay.simulateCommand(.play, id: id)
        await r.relay.simulateCommand(.play, id: id)
        await eventually { await r.relay.sent.filter { if case .ack = $0 { true } else { false } }.count == 2 }
        #expect(r.music.commands == [.play])
        let acks = await r.relay.sent.compactMap { if case .ack(let a) = $0 { a } else { nil } }
        #expect(acks[0] == acks[1])
    }

    @Test func staleCommandIsRefusedUnsent() async throws {
        let r = await rig()
        let id = await r.relay.simulateCommand(.pause, issuedAt: Date().addingTimeInterval(-60))
        await eventually { await r.relay.ack(for: id) != nil }
        let ack = try #require(await r.relay.ack(for: id))
        #expect(!ack.accepted)
        #expect(ack.error?.code == .commandExpired)
        #expect(r.music.commands.isEmpty)
    }

    @Test func closedMusicRefusesCommandsWithoutLaunching() async throws {
        let r = await rig()
        r.music.running = false
        r.companion.refresh()
        await eventually { await states(r.relay).last?.state == .notRunning }
        let scriptsBefore = r.music.scripts.count
        let id = await r.relay.simulateCommand(.play)
        await eventually { await r.relay.ack(for: id) != nil }
        let ack = try #require(await r.relay.ack(for: id))
        #expect(ack.error?.code == .musicNotRunning)
        #expect(r.music.scripts.count == scriptsBefore)   // not a single Apple Event
        #expect(await states(r.relay).last?.listeningSessionID == nil)
    }

    @Test func unknownCommandKindIsRejectedByID() async throws {
        let r = await rig()
        let id = UUID()
        await r.relay.simulateJSON(Data(#"{"type":"command","command":{"id":"\#(id.uuidString)","kind":"seek"}}"#.utf8))
        await eventually { await r.relay.ack(for: id) != nil }
        #expect(await r.relay.ack(for: id)?.error?.code == .unsupportedCommand)
    }

    @Test func artworkIsIdentifiedRequestedAndUploaded() async throws {
        let r = await rig()
        let expectedID = ArtworkID.make(sourceBytes: r.music.current.artwork!)
        let state = try #require(await states(r.relay).last)
        #expect(state.track?.artworkID == expectedID)
        await eventually { await r.relay.uploads[expectedID] != nil }
        let descriptor = try #require(await r.relay.uploads[expectedID])
        #expect(descriptor.contentType == "image/jpeg")
        #expect(descriptor.width == 600)
        #expect(await r.relay.sent.contains(.artwork(descriptor)))
        #expect(r.companion.artwork?.artworkID == expectedID)
    }

    // MARK: Catalogue artwork, for tracks Music has none for

    private static let bareTrack = FakeMusic.Track(title: "Idontknow", artist: "Jamie xx", album: "Idontknow",
                                                   duration: 240.5, pid: "542CEB17C137B3A5", artwork: nil)

    @Test func catalogueArtworkFollowsInALaterStateAndIsServed() async throws {
        let catalogue = FakeCatalogue(.image(FakeMusic.png(side: 400)))
        let r = await rig(tracks: [Self.bareTrack], artworkLookup: catalogue)
        let first = try #require(await states(r.relay).first)
        #expect(first.track?.artworkID == nil, "the title isn't held up for the lookup")
        await eventually { await states(r.relay).last?.track?.artworkID != nil }
        let later = try #require(await states(r.relay).last)
        let expectedID = ArtworkID.make(sourceBytes: FakeMusic.png(side: 400))
        #expect(later.track?.artworkID == expectedID)
        #expect(later.revision > first.revision)
        #expect(await catalogue.queries == [CatalogQuery(title: "Idontknow", artist: "Jamie xx", album: "Idontknow", duration: 240.5)])
        await eventually { await r.relay.uploads[expectedID] != nil }
        #expect(await r.relay.uploads[expectedID]?.width == 400)
    }

    @Test func catalogueIsAskedOncePerTrack() async throws {
        let catalogue = FakeCatalogue(.image(FakeMusic.png(side: 400)))
        let r = await rig(tracks: [Self.bareTrack], artworkLookup: catalogue)
        await eventually { await states(r.relay).last?.track?.artworkID != nil }
        r.music.position = 120
        r.companion.refresh()
        await eventually { await states(r.relay).last.map { abs($0.elapsedTime - 120) < 1 } ?? false }
        #expect(await states(r.relay).last?.track?.artworkID != nil)
        #expect(await catalogue.queries.count == 1)
    }

    @Test func musicsOwnArtworkMeansNoLookup() async throws {
        let catalogue = FakeCatalogue(.image(FakeMusic.png(side: 400)))
        let r = await rig(artworkLookup: catalogue)
        let state = try #require(await states(r.relay).last)
        #expect(state.track?.artworkID == ArtworkID.make(sourceBytes: r.music.current.artwork!))
        await r.companion.settle()
        #expect(await catalogue.queries.isEmpty)
    }

    @Test func noCatalogueMatchLeavesTheTrackWithoutArtwork() async throws {
        let catalogue = FakeCatalogue(.noMatch)
        let r = await rig(tracks: [Self.bareTrack], artworkLookup: catalogue)
        await eventually { r.companion.events.contains { $0.text.hasPrefix("no catalogue artwork matches") } }
        await r.companion.settle()
        #expect(await states(r.relay).allSatisfy { $0.track?.artworkID == nil })
    }

    @Test func aFailedLookupIsNotRetriedOnEveryRead() async throws {
        let catalogue = FakeCatalogue(.failure)
        let r = await rig(tracks: [Self.bareTrack], artworkLookup: catalogue)
        await eventually { r.companion.events.contains { $0.text.hasPrefix("catalogue artwork lookup failed") } }
        r.music.position = 60
        r.companion.refresh()
        await eventually { await states(r.relay).last.map { abs($0.elapsedTime - 60) < 1 } ?? false }
        #expect(await catalogue.queries.count == 1)
    }

    // MARK: Artwork across skips

    private func skip(_ r: Rig) async {
        let id = await r.relay.simulateCommand(.next)
        await eventually { await r.relay.ack(for: id) != nil }
    }

    /// An autoplay queue: Music gives every song the same persistent ID.
    @Test func songsSharingAPersistentIDGetTheirOwnArtwork() async throws {
        let a = FakeMusic.Track(title: "Burnham Beeches Summer", artist: "Empire", album: "Empire", duration: 200, pid: "3C97D19625454E5C", artwork: FakeMusic.png(side: 800))
        let b = FakeMusic.Track(title: "Dreamland", artist: "Glass Animals", album: "Dreamland", duration: 214, pid: "3C97D19625454E5C", artwork: FakeMusic.png(side: 300))
        let r = await rig(tracks: [a, b])
        let first = try #require(await states(r.relay).last)
        await skip(r)
        await eventually { await states(r.relay).last?.track?.title == "Dreamland" }
        let second = try #require(await states(r.relay).last)
        #expect(second.track?.id != first.track?.id)
        #expect(second.track?.artworkID == ArtworkID.make(sourceBytes: FakeMusic.png(side: 300)))
    }

    @Test func theCatalogueIsAskedForEachSongEvenWithASharedPersistentID() async throws {
        let a = FakeMusic.Track(title: "Elsewhere", artist: "Hazlett", album: "The Happiest Times", duration: 201, pid: "3C97D19625454E5C", artwork: nil)
        let b = FakeMusic.Track(title: "Come Back To You", artist: "Vera", album: "Vera", duration: 188, pid: "3C97D19625454E5C", artwork: nil)
        let catalogue = FakeCatalogue(.image(FakeMusic.png(side: 400)))
        let r = await rig(tracks: [a, b], artworkLookup: catalogue)
        await eventually { await catalogue.queries.count == 1 }
        await skip(r)
        await eventually { await catalogue.queries.count == 2 }
        #expect(await catalogue.queries.map(\.title) == ["Elsewhere", "Come Back To You"])
    }

    @Test func thePreviousSongsArtworkRightAfterASkipIsReadAgain() async throws {
        let a = FakeMusic.Track(title: "Losing My Edge", artist: "LCD Soundsystem", album: "LCD Soundsystem", duration: 473, pid: "542CEB17C137B39E", artwork: FakeMusic.png(side: 800))
        let c = FakeMusic.Track(title: "Dreamland", artist: "Glass Animals", album: "Dreamland", duration: 214, pid: "542CEB17C137B3AC", artwork: FakeMusic.png(side: 300))
        let r = await rig(tracks: [a, c])
        r.music.returnPreviousArtworkAfterSkip(reads: 1)
        await skip(r)
        await eventually { r.companion.events.contains { $0.text.hasPrefix("artwork matches the previous track's") } }
        let right = ArtworkID.make(sourceBytes: FakeMusic.png(side: 300)), wrong = ArtworkID.make(sourceBytes: FakeMusic.png(side: 800))
        #expect(await states(r.relay).last?.track?.artworkID != wrong)
        r.companion.refresh()
        await eventually { await states(r.relay).last?.track?.artworkID == right }
        #expect(await states(r.relay).filter { $0.track?.title == "Dreamland" }.allSatisfy { $0.track?.artworkID != wrong })
    }

    /// Seen on 11 Nov 2026: Music went on returning the previous song's image.
    @Test func artworkThatStaysThePreviousSongsFallsBackToTheCatalogue() async throws {
        final class Clock: @unchecked Sendable { var date = Date() }
        let clock = Clock()
        let a = FakeMusic.Track(title: "Magic Wand", artist: "The Avalanches", album: "Magic Wand", duration: 230, pid: "3C97D19625454E5C", artwork: FakeMusic.png(side: 800))
        let c = FakeMusic.Track(title: "Sunshine", artist: "Clancy", album: "Sunshine", duration: 190, pid: "3C97D19625454E5C", artwork: FakeMusic.png(side: 300))
        let catalogue = FakeCatalogue(.image(FakeMusic.png(side: 400)))
        let r = await rig(now: { clock.date }, tracks: [a, c], artworkLookup: catalogue)
        r.music.returnPreviousArtworkAfterSkip(reads: 1000)
        await skip(r)
        await eventually { r.companion.events.contains { $0.text.hasPrefix("artwork matches the previous track's") } }
        clock.date = clock.date.addingTimeInterval(Companion.staleArtworkWindow + 1)
        r.companion.refresh()
        let fromCatalogue = ArtworkID.make(sourceBytes: FakeMusic.png(side: 400))
        await eventually { await states(r.relay).last?.track?.artworkID == fromCatalogue }
        #expect(await catalogue.queries.map(\.title) == ["Sunshine"])
        #expect(await states(r.relay).filter { $0.track?.title == "Sunshine" }.allSatisfy { $0.track?.artworkID != ArtworkID.make(sourceBytes: FakeMusic.png(side: 800)) })
    }

    /// Music can report the previous track's image, then none, right after a
    /// skip; its artwork is read only once the track has settled.
    @Test func musicsArtworkIsReadOnlyOnceTheTrackHasSettled() async throws {
        let a = FakeMusic.Track(title: "Thinkin Bout You", artist: "Frank Ocean", album: "channel ORANGE", duration: 200, pid: "3C97D19625454E5C", artwork: FakeMusic.png(side: 800))
        let b = FakeMusic.Track(title: "All That I've Been Feeling", artist: "Sycco", album: "Sycco", duration: 210, pid: "3C97D19625454E5C", artwork: FakeMusic.png(side: 300))
        let r = await rig(tracks: [a, b])
        r.companion.artworkSettle = 0.5
        let reads = r.music.scripts.filter { if case .artwork = $0 { true } else { false } }.count
        await skip(r)
        await eventually { await states(r.relay).last?.track?.title == "All That I've Been Feeling" }
        #expect(await states(r.relay).last?.track?.artworkID == nil, "too soon after the skip")
        #expect(r.music.scripts.filter { if case .artwork = $0 { true } else { false } }.count == reads)
        await eventually { await states(r.relay).last?.track?.artworkID == ArtworkID.make(sourceBytes: FakeMusic.png(side: 300)) }
    }

    @Test func artworkSharedWithinAnAlbumIsKeptAtOnce() async throws {
        let art = FakeMusic.png(side: 500)
        let a = FakeMusic.Track(title: "Sea Wall", artist: "Glass Animals", album: "Dreamland", duration: 200, pid: "542CEB17C137B3B1", artwork: art)
        let b = FakeMusic.Track(title: "Dreamland", artist: "Glass Animals", album: "Dreamland", duration: 214, pid: "542CEB17C137B3B2", artwork: art)
        let r = await rig(tracks: [a, b])
        await skip(r)
        await eventually { await states(r.relay).last?.track?.title == "Dreamland" }
        #expect(await states(r.relay).last?.track?.artworkID == ArtworkID.make(sourceBytes: art))
        #expect(!r.companion.events.contains { $0.text.hasPrefix("artwork matches the previous track's") })
    }

    @Test func unknownArtworkRequestGetsAnError() async {
        let r = await rig()
        await r.relay.simulate(.artworkRequest(artworkID: String(repeating: "0", count: 64)))
        await eventually { await r.relay.sent.contains { if case .error(let e) = $0 { e.code == .artworkUnavailable } else { false } } }
    }

    @Test func reconnectResendsTheSameState() async throws {
        let r = await rig()
        let before = try #require(await states(r.relay).last)
        await r.relay.simulateDrop(retryAt: Date())
        await r.relay.connect(hello: Hello(device: Self.device))
        await eventually { await states(r.relay).count >= 2 }
        let resent = try #require(await states(r.relay).last)
        #expect(resent == before)
    }

    @Test func quittingSaysGoodbye() async {
        let r = await rig()
        await r.companion.stop()
        #expect(await r.relay.sent.last == .goodbye(reason: "app_quit"))
    }

    @Test func revisionsKeepRisingAcrossARestartEvenIfTheClockGoesBack() async throws {
        let defaults = UserDefaults(suiteName: "CompanionTests-\(UUID().uuidString)")!
        let first = await rig(defaults: defaults)
        let last = try #require(await states(first.relay).last).revision
        await first.companion.stop()
        let second = await rig(defaults: defaults, now: { Date(timeIntervalSince1970: 0) })
        let next = try #require(await states(second.relay).last).revision
        #expect(next > last)
        await second.companion.stop()
    }

    @Test func menuControlsUseTheSamePath() async throws {
        let r = await rig()
        r.companion.perform(.playPause)
        await eventually { await states(r.relay).last?.state == .paused }
        #expect(r.music.commands == [.playPause])
        #expect(r.companion.lastAck == nil)   // no ack for a local command
    }
}

extension CompanionTests {
    /// Found against real Music: a read from before a command, applied after it.
    @Test func olderReadArrivingLateIsDropped() async throws {
        let r = await rig()
        let latest = try #require(await states(r.relay).last)
        let stale = MusicSnapshot(state: .paused, position: 1, capturedAt: latest.capturedAt.addingTimeInterval(-1),
                                  track: MusicTrack(title: "Old", artist: "A", album: "B", duration: 100, persistentID: "OLD"))
        r.companion.monitor.onSnapshot?(stale, .notification)
        await r.companion.settle()
        #expect(await states(r.relay).last == latest)
        #expect(r.companion.snapshot?.track?.title == "Losing My Edge")
    }
}

extension CompanionTests {
    /// Seen live: after a relaunch Music is stopped with nothing loaded, and
    /// takes "next track" as a success that does nothing.
    @Test func skipWithNothingLoadedIsRefused() async throws {
        let r = await rig()
        r.music.running = false
        r.companion.refresh()
        await eventually { await states(r.relay).last?.state == .notRunning }
        r.music.running = true
        r.music.state = "stopped"   // relaunched, nothing loaded
        let id = await r.relay.simulateCommand(.next)
        await eventually { await r.relay.ack(for: id) != nil }
        #expect(await r.relay.ack(for: id)?.error?.code == .noCurrentTrack)
        #expect(r.music.commands.isEmpty)
        #expect(await states(r.relay).last?.state == .stopped)
    }
}

extension CompanionTests {
    /// Unpaired from the phone, or the relay was reset: the owner re-registers.
    @Test func aRejectedCredentialIsReportedOnce() async throws {
        let r = await rig()
        var calls = 0
        r.companion.onCredentialsRejected = { calls += 1 }
        await r.relay.simulateStatus(.failed(ProtocolError(.pairingRevoked)))
        await eventually { calls == 1 }
        await r.relay.simulateStatus(.reconnecting(at: Date(), after: ProtocolError(.notConnected)))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(calls == 1)
        #expect(r.companion.pairedPhone == nil)
    }
}
