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
                     tracks: [FakeMusic.Track] = FakeMusic.standardTracks, artworkLookup: (any CatalogArtworkLookup)? = nil,
                     remote: (any MusicRemoteReading)? = nil) async -> Rig {
        let music = FakeMusic(tracks: tracks, state: state)
        let relay = MockRelayTransport()
        let defaults = defaults ?? UserDefaults(suiteName: "CompanionTests-\(UUID().uuidString)")!
        let companion = Companion(controller: MusicController(runner: music, isRunning: music.processCheck),
                                  transport: relay, store: CompanionStore(defaults: defaults), device: Self.device,
                                  artworkLookup: artworkLookup, now: now, isMusicLaunching: { false })
        companion.settleDelay = .zero
        companion.artworkSettle = 0
        for state in PlaybackState.allCases { companion.monitor.pollIntervals[state] = .seconds(3600) }
        companion.remote = remote
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

    // MARK: Continue from iPhone (docs/relay/API-v1.md §14)

    @Test func continueOnIPhonesPauseOffersContinueFromIPhoneUntilMusicPlaysHere() async throws {
        let r = await rig()
        let plain = await r.relay.simulateCommand(.pause)
        await eventually { await r.relay.ack(for: plain) != nil }
        #expect(!r.companion.phoneHasMusic, "an ordinary pause doesn't")
        r.music.state = "playing"
        let marked = await r.relay.simulate(RemoteCommand(kind: .pause, reason: .continueOnPhone))
        await eventually { await r.relay.ack(for: marked)?.accepted == true }
        #expect(r.companion.phoneHasMusic)
        #expect(r.companion.events.contains { $0.text.contains("pause (continue_on_phone)") })
        let play = await r.relay.simulateCommand(.play)
        await eventually { await r.relay.ack(for: play) != nil }
        await eventually { !r.companion.phoneHasMusic }
    }

    @Test func continueFromIPhoneAsksTheRelayAndFollowsItsAnswers() async throws {
        let r = await rig(state: "paused")
        r.companion.continueFromPhone()
        let progress = try #require(r.companion.handBack)
        #expect(progress.status == nil && !progress.isFinished)
        await eventually { await r.relay.sent.contains(.handBackRequest(id: progress.id)) }
        await r.relay.simulate(.handBackStatus(id: UUID(), status: .done))   // someone else's
        await r.relay.simulate(.handBackStatus(id: progress.id, status: .asked))
        await eventually { r.companion.handBack?.status == .asked }
        await r.relay.simulate(.handBackStatus(id: progress.id, status: .working))
        await eventually { r.companion.handBack?.status == .working }
        await r.relay.simulate(.handBackStatus(id: progress.id, status: .done))
        await eventually { r.companion.handBack?.isFinished == true }
        // The phone's play arrives; once Music plays here the row goes.
        let play = await r.relay.simulateCommand(.play)
        await eventually { await r.relay.ack(for: play) != nil }
        await eventually { r.companion.handBack == nil }
    }

    @Test func continueFromIPhoneGivesUpWhenNothingAnswers() async throws {
        let r = await rig(state: "paused")
        r.companion.handBackTimeout = .milliseconds(50)
        r.companion.continueFromPhone()
        await eventually { r.companion.handBack?.timedOut == true }
        #expect(r.companion.handBack?.isFinished == true)
        // A late answer still counts.
        await r.relay.simulate(.handBackStatus(id: r.companion.handBack!.id, status: .working))
        await eventually { r.companion.handBack?.timedOut == false && r.companion.handBack?.status == .working }
    }

    @Test func continueFromIPhoneSaysAtOnceWhenTheRelayIsntThere() async throws {
        let r = await rig(state: "paused")
        await r.relay.simulateDrop(retryAt: Date().addingTimeInterval(30))
        await eventually { r.companion.connection.phase != .connected }
        r.companion.continueFromPhone()
        #expect(r.companion.handBack?.status == .unreachable)
        #expect(await !r.relay.sent.contains { if case .handBackRequest = $0 { true } else { false } })
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
        await r.relay.simulateJSON(Data(#"{"type":"command","command":{"id":"\#(id.uuidString)","kind":"shuffle"}}"#.utf8))
        await eventually { await r.relay.ack(for: id) != nil }
        #expect(await r.relay.ack(for: id)?.error?.code == .unsupportedCommand)
    }

    @Test func seekFromThePhoneMovesMusicAndIsClampedToTheTrack() async throws {
        let r = await rig()
        let id = await r.relay.simulate(.seek(to: 120.5))
        await eventually { await r.relay.ack(for: id) != nil }
        #expect(await r.relay.ack(for: id)?.accepted == true)
        #expect(r.music.position == 120.5)
        await eventually { await states(r.relay).last?.elapsedTime == 120.5 }
        let far = await r.relay.simulate(.seek(to: 9_999))
        await eventually { await r.relay.ack(for: far) != nil }
        #expect(r.music.position == 473.114, "clamped to the track's duration")
    }

    @Test func volumeFromThePhoneSetsMusicsOwnVolumeAndIsReported() async throws {
        let r = await rig()
        #expect(await states(r.relay).last?.volume == 1.0, "the first state carries Music's volume")
        let id = await r.relay.simulate(.setVolume(0.4))
        await eventually { await r.relay.ack(for: id) != nil }
        #expect(await r.relay.ack(for: id)?.accepted == true)
        #expect(r.music.volume == 40)
        await eventually { await states(r.relay).last?.volume == 0.4 }
        let loud = await r.relay.simulate(.setVolume(7))
        await eventually { await r.relay.ack(for: loud) != nil }
        #expect(r.music.volume == 100, "clamped to 0…1")
    }

    @Test func outputFromThePhoneSwitchesMusicToThatDeviceAlone() async throws {
        let r = await rig()
        let first = try #require(await states(r.relay).last)
        let homePod = try #require(first.outputs?.first { $0.kind == .homePod })
        #expect(first.outputs?.filter(\.isSelected).map(\.name) == ["Test Mac"])
        #expect(first.outputs?.first { $0.name == "Bedroom Apple TV" }?.isAvailable == false)
        let id = await r.relay.simulate(.selectOutput(homePod.id))
        await eventually { await r.relay.ack(for: id) != nil }
        #expect(await r.relay.ack(for: id)?.accepted == true)
        #expect(r.music.selectedOutputs == ["Study HomePod"])
        await eventually { await states(r.relay).last?.outputs?.filter(\.isSelected).map(\.name) == ["Study HomePod"] }
        let unknown = await r.relay.simulate(.selectOutput("00:11:22:33:44:55"))
        await eventually { await r.relay.ack(for: unknown) != nil }
        #expect(await r.relay.ack(for: unknown)?.error?.code == .invalidRequest)
        #expect(r.music.selectedOutputs == ["Study HomePod"])
    }

    @Test func aValueCommandWithoutItsValueIsInvalidAndNeverReachesMusic() async throws {
        let r = await rig()
        let before = r.music.scripts.count
        for command in [RemoteCommand(kind: .seek), RemoteCommand(kind: .setVolume), RemoteCommand(kind: .selectOutput, outputID: "")] {
            let id = await r.relay.simulate(command)
            await eventually { await r.relay.ack(for: id) != nil }
            #expect(await r.relay.ack(for: id)?.error?.code == .invalidRequest)
        }
        #expect(r.music.scripts.count == before)
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

    /// Music's remote protocol, giving artwork (or none) after a delay.
    private actor ArtworkRemote: MusicRemoteReading {
        let image: Data?
        let delay: Duration
        private(set) var asked: [String] = []
        init(_ image: Data?, after delay: Duration = .zero) { self.image = image; self.delay = delay }
        func queue(current track: MusicTrack?) async -> RemoteQueue? { nil }
        func artwork(for track: MusicTrack) async -> Data? {
            asked.append(track.title)
            try? await Task.sleep(for: delay)
            return image
        }
    }

    @Test func musicsRemoteArtworkComesBeforeTheCatalogue() async throws {
        let catalogue = FakeCatalogue(.image(FakeMusic.png(side: 400)))
        let remote = ArtworkRemote(FakeMusic.png(side: 300))
        let r = await rig(tracks: [Self.bareTrack], artworkLookup: catalogue, remote: remote)
        let expectedID = ArtworkID.make(sourceBytes: FakeMusic.png(side: 300))
        await eventually { await states(r.relay).last?.track?.artworkID == expectedID }
        await eventually { await r.relay.uploads[expectedID] != nil }
        #expect(await r.relay.uploads[expectedID]?.width == 300)
        await r.companion.settle()
        #expect(await catalogue.queries.isEmpty)
        #expect(await remote.asked == ["Idontknow"])
    }

    @Test func slowRemoteArtworkFollowsInALaterState() async throws {
        let catalogue = FakeCatalogue(.image(FakeMusic.png(side: 400)))
        let remote = ArtworkRemote(FakeMusic.png(side: 300), after: .milliseconds(800))
        let r = await rig(tracks: [Self.bareTrack], artworkLookup: catalogue, remote: remote)
        let first = try #require(await states(r.relay).first)
        #expect(first.track?.artworkID == nil, "the title isn't held up for Music's artwork")
        let expectedID = ArtworkID.make(sourceBytes: FakeMusic.png(side: 300))
        await eventually { await states(r.relay).last?.track?.artworkID == expectedID }
        #expect(await catalogue.queries.isEmpty, "a slow answer isn't taken as none")
        #expect(await remote.asked.count == 1)
    }

    @Test func noRemoteArtworkFallsBackToTheCatalogue() async throws {
        let catalogue = FakeCatalogue(.image(FakeMusic.png(side: 400)))
        let remote = ArtworkRemote(nil)
        let r = await rig(tracks: [Self.bareTrack], artworkLookup: catalogue, remote: remote)
        await eventually { await states(r.relay).last?.track?.artworkID == ArtworkID.make(sourceBytes: FakeMusic.png(side: 400)) }
        r.music.position = 120
        r.companion.refresh()
        await eventually { await states(r.relay).last.map { abs($0.elapsedTime - 120) < 1 } ?? false }
        #expect(await remote.asked.count == 1, "a miss isn't asked again on every read")
        #expect(await catalogue.queries.count == 1)
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

    /// The next song from the same album shows the album's artwork with its
    /// title, before Music's own can be trusted.
    @Test func theNextSongFromTheSameAlbumGetsItsArtworkAtOnce() async throws {
        let art = FakeMusic.png(side: 500)
        let a = FakeMusic.Track(title: "Sea Wall", artist: "Glass Animals", album: "Dreamland", duration: 200, pid: "542CEB17C137B3B1", artwork: art)
        let b = FakeMusic.Track(title: "Dreamland", artist: "Glass Animals", album: "Dreamland", duration: 214, pid: "542CEB17C137B3B2", artwork: art)
        let r = await rig(tracks: [a, b])
        r.companion.artworkSettle = 0.5
        let reads = r.music.scripts.filter { if case .artwork = $0 { true } else { false } }.count
        await skip(r)
        await eventually { await states(r.relay).contains { $0.track?.title == "Dreamland" } }
        let first = try #require(await states(r.relay).first { $0.track?.title == "Dreamland" })
        #expect(first.track?.artworkID == ArtworkID.make(sourceBytes: art))
        #expect(r.music.scripts.filter { if case .artwork = $0 { true } else { false } }.count == reads, "Music not asked yet")
    }

    /// The stand-in is replaced once Music's own artwork can be read.
    @Test func aSameAlbumStandInGivesWayToTheSongsOwnArtwork() async throws {
        let a = FakeMusic.Track(title: "Sea Wall", artist: "Glass Animals", album: "Dreamland", duration: 200, pid: "542CEB17C137B3B1", artwork: FakeMusic.png(side: 500))
        let b = FakeMusic.Track(title: "Dreamland", artist: "Glass Animals", album: "Dreamland", duration: 214, pid: "542CEB17C137B3B2", artwork: FakeMusic.png(side: 300))
        let r = await rig(tracks: [a, b])
        r.companion.artworkSettle = 0.3
        await skip(r)
        await eventually { await states(r.relay).last?.track?.artworkID == ArtworkID.make(sourceBytes: FakeMusic.png(side: 300)) }
        let first = try #require(await states(r.relay).first { $0.track?.title == "Dreamland" })
        #expect(first.track?.artworkID == ArtworkID.make(sourceBytes: FakeMusic.png(side: 500)))
    }

    /// Same album name, another artist: not the same album, so no stand-in.
    @Test func anAlbumOfTheSameNameByAnotherArtistWaitsForMusic() async throws {
        let a = FakeMusic.Track(title: "Heroes", artist: "David Bowie", album: "Greatest Hits", duration: 200, pid: "542CEB17C137B3C1", artwork: FakeMusic.png(side: 500))
        let b = FakeMusic.Track(title: "Dancing Queen", artist: "ABBA", album: "Greatest Hits", duration: 230, pid: "542CEB17C137B3C2", artwork: FakeMusic.png(side: 300))
        let r = await rig(tracks: [a, b])
        r.companion.artworkSettle = 0.5
        await skip(r)
        await eventually { await states(r.relay).contains { $0.track?.title == "Dancing Queen" } }
        let first = try #require(await states(r.relay).first { $0.track?.title == "Dancing Queen" })
        #expect(first.track?.artworkID == nil)
        await eventually { await states(r.relay).last?.track?.artworkID == ArtworkID.make(sourceBytes: FakeMusic.png(side: 300)) }
    }

    /// Music handing out the previous song's image is asked again soon, not on
    /// the next poll (which these tests put an hour away).
    @Test func thePreviousSongsArtworkIsReadAgainWithoutWaitingForAPoll() async throws {
        let a = FakeMusic.Track(title: "Losing My Edge", artist: "LCD Soundsystem", album: "LCD Soundsystem", duration: 473, pid: "542CEB17C137B39E", artwork: FakeMusic.png(side: 800))
        let c = FakeMusic.Track(title: "Dreamland", artist: "Glass Animals", album: "Dreamland", duration: 214, pid: "542CEB17C137B3AC", artwork: FakeMusic.png(side: 300))
        let r = await rig(tracks: [a, c])
        r.music.returnPreviousArtworkAfterSkip(reads: 1)
        let skipped = ContinuousClock.now
        await skip(r)
        await eventually { await states(r.relay).last?.track?.artworkID == ArtworkID.make(sourceBytes: FakeMusic.png(side: 300)) }
        #expect(ContinuousClock.now - skipped < .milliseconds(1500), "about half a second, not a poll later")
        #expect(r.companion.events.contains { $0.text.hasPrefix("artwork matches the previous track's") })
    }

    @Test func albumKeyUsesTheAlbumArtistWhenThereIsOne() {
        let feat = MusicTrack(title: "a", artist: "X feat. Y", album: "Album", albumArtist: "X", duration: 1)
        let plain = MusicTrack(title: "b", artist: "X", album: "Album", albumArtist: "", duration: 1)
        #expect(Companion.albumKey(feat) == Companion.albumKey(plain))
        #expect(Companion.albumKey(MusicTrack(title: "c", artist: "X", album: "", duration: 1)) == nil)
    }

    /// The phone's extension gets about a second after an update to fetch the
    /// image; the relay must already have it.
    @Test func artworkIsUploadedBeforeTheStateThatNamesIt() async throws {
        let r = await rig()
        let id = ArtworkID.make(sourceBytes: r.music.current.artwork!)
        await eventually { await r.relay.uploads[id] != nil }
        let timeline = await r.relay.timeline
        let upload = try #require(timeline.firstIndex(of: "upload \(id)"))
        let state = try #require(timeline.firstIndex(of: "state \(id)"))
        #expect(upload < state)
        #expect(!(await r.relay.sent).contains { if case .error = $0 { true } else { false } })
        #expect(timeline.filter { $0 == "upload \(id)" }.count == 1, "sent once, not again when the relay would ask")
    }

    @Test func waitAtMostGivesUpButLetsTheWorkFinish() async {
        let slow = await Companion.waitAtMost(.milliseconds(50)) { () -> Int in
            try? await Task.sleep(for: .milliseconds(500))
            return 1
        }
        #expect(slow == nil)
        #expect(await Companion.waitAtMost(.seconds(1)) { 7 } == 7)
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
