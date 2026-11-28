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
        companion.skipSpacing = .zero
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

    /// Going to sleep: the last state, then goodbye "sleep", then no
    /// connection until the Mac wakes; waking says hello again (25 November 2026).
    @Test func sleepSaysGoodbyeAndWakeReconnects() async throws {
        let r = await rig()
        await r.companion.willSleep()
        let sent = await r.relay.sent
        guard case .goodbye(let reason) = sent.last else { Issue.record("last frame was not goodbye: \(sent.last.map(String.init(describing:)) ?? "none")"); return }
        #expect(reason == "sleep")
        #expect(await r.relay.isConnected == false)
        #expect(r.companion.isAsleep)
        await r.companion.willSleep()
        #expect(await r.relay.sent.count == sent.count, "a second sleep notice sends nothing more")
        let before = await r.relay.sent.count
        await r.companion.didWake()
        #expect(!r.companion.isAsleep)
        #expect(await r.relay.isConnected)
        await eventually { await r.relay.sent.dropFirst(before).contains { if case .hello = $0 { true } else { false } } }
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

    @Test func continueFromIPhoneIsOfferedWheneverMusicHereIsntPlaying() async throws {
        let r = await rig(state: "playing")
        let phone = DeviceIdentity(id: "p1", name: "iPhone", kind: .iPhone, appVersion: nil, osVersion: nil)
        await r.relay.simulate(.paired(phone: phone))
        await eventually { r.companion.pairedPhone == phone }
        #expect(!r.companion.offersContinueFromPhone, "not while Music plays here")
        r.music.state = "paused"
        r.companion.refresh()
        #expect(await eventually { r.companion.offersContinueFromPhone }, "paused here, though the phone got its music some other way")
        r.music.state = "stopped"
        r.companion.refresh()
        #expect(await eventually { r.companion.snapshot?.state == .stopped })
        #expect(r.companion.offersContinueFromPhone)
    }

    @Test func continueFromIPhoneIsStillOfferedAfterARestart() async throws {
        let defaults = UserDefaults(suiteName: "CompanionTests-\(UUID().uuidString)")!
        let first = await rig(state: "playing", defaults: defaults)
        let marked = await first.relay.simulate(RemoteCommand(kind: .pause, reason: .continueOnPhone))
        await eventually { await first.relay.ack(for: marked)?.accepted == true }
        #expect(first.companion.phoneHasMusic)
        // The app restarts with Music still paused.
        let again = await rig(state: "paused", defaults: defaults)
        #expect(again.companion.phoneHasMusic)
        // Music playing here ends it, and that's kept too.
        let play = await again.relay.simulateCommand(.play)
        await eventually { await again.relay.ack(for: play) != nil }
        await eventually { !again.companion.phoneHasMusic }
        #expect(await rig(state: "paused", defaults: defaults).companion.phoneHasMusic == false)
    }

    @Test func aReadFromBeforeThePauseDoesntTakeContinueFromIPhoneAway() async throws {
        let r = await rig()
        r.companion.settleDelay = .milliseconds(300)
        let marked = await r.relay.simulate(RemoteCommand(kind: .pause, reason: .continueOnPhone))
        await eventually { await r.relay.ack(for: marked)?.accepted == true }
        // A read taken while Music still said playing lands after the pause.
        r.music.state = "playing"
        r.companion.refresh()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(r.companion.phoneHasMusic)
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

    /// 28 November 2026: the phone's playlist or album isn't in the library
    /// and its setting is Ask Every Time, so the question is asked here and
    /// the answer goes in a new request.
    @MainActor final class Asked {
        var answers: [LibraryDialogAnswer?]
        var asked: [Bool] = []
        var items: [HandBackLibraryItem?] = []
        var open: CheckedContinuation<Void, Never>?
        var holds = false
        init(_ answers: LibraryDialogAnswer?...) { self.answers = answers }
        func ask(_ addFailed: Bool, _ item: HandBackLibraryItem? = nil) async -> LibraryDialogAnswer? {
            asked.append(addFailed)
            items.append(item)
            if holds { await withCheckedContinuation { open = $0 } }
            return answers.isEmpty ? nil : answers.removeFirst()
        }
    }

    private func requests(_ r: Rig) async -> [(id: UUID, library: HandBackLibraryChoice?, remember: Bool?)] {
        await r.relay.sent.compactMap {
            if case .handBackRequest(let id, let library, let remember) = $0 { return (id, library, remember) }
            return nil
        }
    }

    @Test func continueFromIPhoneAsksAboutTheLibraryAndSendsTheAnswer() async throws {
        let r = await rig(state: "paused")
        let person = Asked(LibraryDialogAnswer(choice: .add, remember: true))
        r.companion.askLibrary = { await person.ask($0, $1) }
        r.companion.continueFromPhone()
        let first = try #require(r.companion.handBack)
        await eventually { await requests(r).count == 1 }
        #expect(await requests(r).first?.library == .ask, "the menu can ask")
        let today = HandBackLibraryItem(kind: HandBackLibraryItem.playlist, name: "Today")
        await r.relay.simulate(.handBackStatus(id: first.id, status: .needsLibraryChoice, item: today))
        await eventually { await requests(r).count == 2 }
        #expect(person.items == [today], "the dialog names what the phone plays")
        let second = try #require(await requests(r).last)
        #expect(second.library == .add && second.remember == true)
        #expect(second.id != first.id && r.companion.handBack?.id == second.id)
        #expect(r.companion.handBack?.isWaiting == true && r.companion.handBack?.askingYou == false)
        await r.relay.simulate(.handBackStatus(id: second.id, status: .working))
        await eventually { r.companion.handBack?.message == "Adding it to your library…" }
        #expect(person.asked == [false])
        // Adding fails on the phone: asked again, with Try Again.
        person.answers = [LibraryDialogAnswer(choice: .station, remember: false)]
        await r.relay.simulate(.handBackStatus(id: second.id, status: .libraryAddFailed))
        await eventually { await requests(r).count == 3 }
        #expect(person.asked == [false, true])
        #expect(await requests(r).last?.library == .station)
    }

    @Test func cancelAtTheMacMovesNothing() async throws {
        let r = await rig(state: "paused")
        let person = Asked(nil)
        r.companion.askLibrary = { await person.ask($0, $1) }
        r.companion.continueFromPhone()
        let id = try #require(r.companion.handBack?.id)
        await eventually { await requests(r).count == 1 }
        await r.relay.simulate(.handBackStatus(id: id, status: .needsLibraryChoice))
        await eventually { r.companion.handBack?.status == .cancelled }
        #expect(r.companion.handBack?.isFinished == true)
        #expect(r.companion.handBack?.message == "Cancelled. Nothing was moved.")
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await requests(r).count == 1, "no second request")
    }

    @Test func oneLibraryDialogAtATime() async throws {
        let r = await rig(state: "paused")
        let person = Asked(LibraryDialogAnswer(choice: .station, remember: false))
        person.holds = true
        r.companion.askLibrary = { await person.ask($0, $1) }
        r.companion.continueFromPhone()
        let id = try #require(r.companion.handBack?.id)
        await eventually { await requests(r).count == 1 }
        await r.relay.simulate(.handBackStatus(id: id, status: .needsLibraryChoice))
        await eventually { person.open != nil }
        // The menu keeps its spinner while the dialog is open.
        #expect(r.companion.handBack?.isWaiting == true && r.companion.handBack?.message == "Waiting for your choice…")
        // Clicked again while the dialog is open: the new request's question shares it.
        r.companion.continueFromPhone()
        let again = try #require(r.companion.handBack?.id)
        await eventually { await requests(r).count == 2 }
        await r.relay.simulate(.handBackStatus(id: again, status: .needsLibraryChoice))
        await eventually { r.companion.handBack?.status == .needsLibraryChoice }
        #expect(person.asked.count == 1)
        person.open?.resume()
        await eventually { await requests(r).count == 3 }
        #expect(await requests(r).last?.library == .station)
    }

    @Test func theShortcutsActionNeverAsks() async throws {
        let r = await rig(state: "paused")
        let person = Asked()
        r.companion.askLibrary = { await person.ask($0, $1) }
        r.companion.continueFromPhone(canAsk: false)
        await eventually { await requests(r).count == 1 }
        #expect(await requests(r).first?.library == nil, "the phone follows its setting; Ask Every Time is the station")
        #expect(person.asked.isEmpty)
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

    /// States carry no AirPlay devices (choosing one from the phone was
    /// dropped, 23 November 2026); the command still works for an id.
    @Test func statesCarryNoOutputsAndSelectOutputStillWorks() async throws {
        let r = await rig()
        let first = try #require(await states(r.relay).last)
        #expect(first.outputs == nil)
        let id = await r.relay.simulate(.selectOutput("f2:b6:61:a7:54:f9"))
        await eventually { await r.relay.ack(for: id) != nil }
        #expect(await r.relay.ack(for: id)?.accepted == true)
        #expect(r.music.selectedOutputs == ["Study HomePod"])
        let unknown = await r.relay.simulate(.selectOutput("00:11:22:33:44:55"))
        await eventually { await r.relay.ack(for: unknown) != nil }
        #expect(await r.relay.ack(for: unknown)?.error?.code == .invalidRequest)
        #expect(r.music.selectedOutputs == ["Study HomePod"])
    }

    @Test func playStationOpensTheSongsStationInMusic() async throws {
        let r = await rig()
        let id = await r.relay.simulate(.playStation(seededBy: "1730817069"))
        await eventually { await r.relay.ack(for: id) != nil }
        #expect(await r.relay.ack(for: id)?.accepted == true)
        let opened = try #require(r.music.openedLocations.first)
        #expect(opened.hasPrefix("music://music.apple.com/") && opened.hasSuffix("/station/ra.1730817069"))
    }

    @Test func theMacSeeksItselfWhenTheStationStartsWithTheSong() async throws {
        let r = await rig(state: "paused")   // on "Losing My Edge"; the station starts with "Idontknow"
        let id = await r.relay.simulate(.playStation(seededBy: "1730817069", position: 61, title: "IDONTKNOW", issuedAt: Date()))
        await eventually { await r.relay.ack(for: id)?.accepted == true }
        #expect(await eventually { r.music.position > 60 }, "seeked to where the phone is, without waiting for the phone")
        #expect(r.music.position < 75)
    }

    @Test func aBurstOfCommandsIsConfirmedBeforeOneSettleRead() async throws {
        let r = await rig()
        r.companion.settleDelay = .milliseconds(400)
        try? await Task.sleep(for: .milliseconds(450))   // the start-up read has settled
        let before = r.music.scripts.filter { $0 == .snapshot }.count
        let started = Date()
        let ids = [await r.relay.simulateCommand(.next), await r.relay.simulateCommand(.next), await r.relay.simulateCommand(.pause)]
        for id in ids { await eventually { await r.relay.ack(for: id) != nil } }
        #expect(Date().timeIntervalSince(started) < 0.3, "no command waited behind a sleeping settle-read")
        #expect(r.music.scripts.filter { $0 == .snapshot }.count == before, "no read has run yet")
        try? await Task.sleep(for: .milliseconds(900))
        let reads = r.music.scripts.filter { $0 == .snapshot }.count - before
        #expect(reads == 1, "one read after the burst, not one per command (\(reads))")
    }

    @Test func skipsAreSpacedSoMusicDoesntDropOne() async throws {
        let r = await rig()
        r.companion.skipSpacing = .milliseconds(400)
        let first = await r.relay.simulateCommand(.next)
        await eventually { await r.relay.ack(for: first) != nil }
        let started = Date()
        let second = await r.relay.simulateCommand(.next)
        await eventually { await r.relay.ack(for: second) != nil }
        #expect(Date().timeIntervalSince(started) >= 0.3, "the second skip waited for the first to settle")
        let pause = await r.relay.simulateCommand(.pause)
        let before = Date()
        await eventually { await r.relay.ack(for: pause) != nil }
        #expect(Date().timeIntervalSince(before) < 0.3, "only skips are spaced")
    }

    @Test func aPausedPhonesPositionIsNotMovedOn() async throws {
        let r = await rig(state: "paused")
        let issued = Date().addingTimeInterval(-3)   // three seconds old: a playing phone would be 3 s further on
        let id = await r.relay.simulate(.playStation(seededBy: "1730817069", position: 30, title: "Idontknow", positionIsPaused: true, issuedAt: issued))
        await eventually { await r.relay.ack(for: id)?.accepted == true }
        #expect(await eventually { r.music.position > 29 })
        #expect(r.music.position < 31, "seeked to where the phone stopped, not three seconds past it (\(r.music.position))")
    }

    @Test func theMacSaysWhereItIsRightAfterItsOwnSeek() async throws {
        let r = await rig(state: "paused")
        await eventually { r.music.position < 20 }
        let id = await r.relay.simulate(.playStation(seededBy: "1730817069", position: 61, title: "Idontknow", issuedAt: Date()))
        await eventually { await r.relay.ack(for: id)?.accepted == true }
        // Polls are an hour apart in this rig, so only the Mac's own refresh can say it.
        let said = await eventually {
            let list = await self.states(r.relay)
            return list.contains { (m: PlaybackMessage) in m.track?.title == "Idontknow" && m.elapsedTime > 60 }
        }
        #expect(said)
    }

    @Test func aStationStartingWithAnotherSongIsLeftWhereItIs() async throws {
        let r = await rig(state: "paused")
        let id = await r.relay.simulate(.playStation(seededBy: "1730817069", position: 61, title: "Some Other Song", issuedAt: Date()))
        await eventually { await r.relay.ack(for: id)?.accepted == true }
        await eventually { r.companion.events.contains { $0.text.contains("another song") } }
        #expect(r.music.position < 5)
    }

    // MARK: Continue on Mac with a playlist (17 November 2026)

    private static let place = PlaylistPlace(name: "Road Trip", cloudID: "pl.u-Zx9yW8vU7tS6r", count: 123, index: 59)

    /// Music's remote protocol as Continue on Mac uses it: records what it
    /// was asked to play, and starts Music's next song when it "plays".
    private final class PlaylistRemote: MusicRemoteReading, MusicRemotePlaying, @unchecked Sendable {
        let outcome: PlaylistPlayOutcome
        let music: FakeMusic
        private let lock = NSLock()
        private var _asked: [(String, PlaylistPlace)] = []
        var asked: [(String, PlaylistPlace)] { lock.withLock { _asked } }
        /// Answers `.notHere` this many times first, as for a playlist still on its way.
        private var notHereFirst: Int
        init(_ outcome: PlaylistPlayOutcome, music: FakeMusic, notHereFirst: Int = 0) {
            self.outcome = outcome
            self.music = music
            self.notHereFirst = notHereFirst
        }
        private func answer() -> PlaylistPlayOutcome {
            lock.withLock {
                guard notHereFirst > 0 else { return outcome }
                notHereFirst -= 1
                return .notHere
            }
        }
        func queue(current track: MusicTrack?) async -> RemoteQueue? { nil }
        func play(_ catalogID: String, in place: PlaylistPlace) async -> PlaylistPlayOutcome {
            lock.withLock { _asked.append((catalogID, place)) }
            let outcome = answer()
            if case .played = outcome { music.startNextSong() }
            return outcome
        }
        private var _library: [String] = []
        var library: [String] { lock.withLock { _library } }
        func playInLibrary(_ catalogID: String, beforeStart: @escaping @Sendable () async -> Void) async -> PlaylistPlayOutcome {
            lock.withLock { _library.append(catalogID) }
            let outcome = answer()
            guard case .played = outcome else { return outcome }
            await beforeStart()
            music.startNextSong()
            return outcome
        }
        private var _albums: [(String, AlbumPlace)] = []
        var albums: [(String, AlbumPlace)] { lock.withLock { _albums } }
        func playAlbum(_ catalogID: String, in place: AlbumPlace, beforeStart: @escaping @Sendable () async -> Void) async -> PlaylistPlayOutcome {
            lock.withLock { _albums.append((catalogID, place)) }
            let outcome = answer()
            guard case .played = outcome else { return outcome }
            await beforeStart()
            music.startNextSong()
            return outcome
        }
    }

    private static let album = AlbumPlace(title: "Made-Up Album", artist: "Made-Up Band", count: 25, index: 9, shuffled: true)

    @Test func anAlbumFromThePhonePlaysInOrderWithShuffleOff() async throws {
        let r = await rig(state: "paused")
        _ = r.music.run(.setShuffle(true))
        let remote = PlaylistRemote(.played(index: 9), music: r.music)
        r.companion.remote = remote
        let id = await r.relay.simulate(.playStation(seededBy: "1730817069", position: 61, title: "Idontknow", album: Self.album, issuedAt: Date()))
        await eventually { await r.relay.ack(for: id) != nil }
        #expect(await r.relay.ack(for: id)?.accepted == true)
        #expect(remote.albums.map(\.0) == ["1730817069"])
        #expect(remote.asked.isEmpty, "not a playlist")
        #expect(r.music.openedLocations.isEmpty, "no station")
        #expect(!r.music.shuffle, "Music can't shuffle within an album, so it plays in order")
        #expect(await eventually { r.music.position > 60 })
        #expect(!r.companion.events.contains { $0.text.contains("Made-Up") })
    }

    @Test func aPlaylistWinsOverAnAlbumAndANoShowAlbumIsTheStation() async throws {
        let r = await rig(state: "paused")
        let remote = PlaylistRemote(.played(index: 59), music: r.music)
        r.companion.remote = remote
        let both = await r.relay.simulate(.playStation(seededBy: "1730817069", position: 61, title: "Idontknow", playlist: Self.place,
                                                       album: Self.album, issuedAt: Date()))
        await eventually { await r.relay.ack(for: both)?.accepted == true }
        #expect(remote.asked.count == 1 && remote.albums.isEmpty)

        let r2 = await rig(state: "paused")
        let missing = PlaylistRemote(.notHere, music: r2.music)
        r2.companion.remote = missing
        let id = await r2.relay.simulate(.playStation(seededBy: "1730817069", album: Self.album, issuedAt: Date()))
        await eventually { await r2.relay.ack(for: id)?.accepted == true }
        #expect(missing.albums.count == 1)
        #expect(r2.music.openedLocations.first?.hasSuffix("/station/ra.1730817069") == true)
    }

    @Test func aPlaylistFromThePhonePlaysFromTheSongInsteadOfTheStation() async throws {
        let r = await rig(state: "paused")   // on "Losing My Edge"; the playlist starts with "Idontknow"
        let remote = PlaylistRemote(.played(index: 59), music: r.music)
        r.companion.remote = remote
        let id = await r.relay.simulate(.playStation(seededBy: "1730817069", position: 61, title: "Idontknow", playlist: Self.place,
                                                     issuedAt: Date()))
        await eventually { await r.relay.ack(for: id) != nil }
        #expect(await r.relay.ack(for: id)?.accepted == true)
        #expect(remote.asked.map(\.0) == ["1730817069"])
        #expect(remote.asked.first?.1 == Self.place)
        #expect(r.music.openedLocations.isEmpty, "no station")
        #expect(await eventually { r.music.position > 60 }, "seeked to where the phone is")
        #expect(!r.music.shuffle)
        #expect(!r.companion.events.contains { $0.text.contains("Road Trip") }, "the playlist's name stays out of the log")
    }

    @Test func aShuffledPlaylistShufflesOnceTheSongPlays() async throws {
        let r = await rig(state: "paused")
        r.companion.remote = PlaylistRemote(.played(index: 59), music: r.music)
        var shuffled = Self.place
        shuffled.shuffled = true
        let id = await r.relay.simulate(.playStation(seededBy: "1730817069", position: 61, title: "Idontknow", playlist: shuffled,
                                                     issuedAt: Date()))
        await eventually { await r.relay.ack(for: id)?.accepted == true }
        #expect(await eventually { r.music.shuffle })
        #expect(await eventually { r.music.position > 60 })
    }

    // MARK: Library shuffle, the phone's station, new playlists, repeat (17 November 2026)

    @Test func theLibraryShuffledPlaysTheSongThenShuffles() async throws {
        let r = await rig(state: "paused")
        _ = r.music.run(.setShuffle(true))
        let remote = PlaylistRemote(.played(index: 3), music: r.music)
        r.companion.remote = remote
        let id = await r.relay.simulate(.playStation(seededBy: "1730817069", position: 61, title: "Idontknow", shuffledLibrary: true,
                                                     repeatMode: .all, issuedAt: Date()))
        await eventually { await r.relay.ack(for: id)?.accepted == true }
        #expect(remote.library == ["1730817069"])
        #expect(r.music.openedLocations.isEmpty, "no station")
        #expect(await eventually { r.music.position > 60 })
        #expect(await eventually { r.music.shuffle }, "shuffle on once the song plays")
        #expect(r.music.repeatMode == .all)
    }

    @Test func theLibraryShuffledWithoutTheSongIsTheStation() async throws {
        let r = await rig(state: "paused")
        let remote = PlaylistRemote(.notHere, music: r.music)
        r.companion.remote = remote
        let id = await r.relay.simulate(.playStation(seededBy: "1730817069", shuffledLibrary: true, issuedAt: Date()))
        await eventually { await r.relay.ack(for: id)?.accepted == true }
        #expect(r.music.openedLocations.first?.hasSuffix("/station/ra.1730817069") == true)
    }

    @Test func thePhonesStationPlaysRatherThanTheSongs() async throws {
        let r = await rig(state: "paused")
        let id = await r.relay.simulate(.playStation(seededBy: "1730817069", position: 61, title: "Idontknow",
                                                     station: StationPlace(id: "ra.985484166", name: "Made-Up Radio"), issuedAt: Date()))
        await eventually { await r.relay.ack(for: id)?.accepted == true }
        #expect(r.music.openedLocations.first?.hasSuffix("/station/ra.985484166") == true)
        #expect(!r.companion.events.contains { $0.text.contains("Made-Up") }, "the station's name stays out of the log")
        // An ID that can't go in a link is the song's station.
        let r2 = await rig(state: "paused")
        let bad = await r2.relay.simulate(.playStation(seededBy: "1730817069", station: StationPlace(id: "ra.x\"; quit", name: "X"),
                                                       issuedAt: Date()))
        await eventually { await r2.relay.ack(for: bad)?.accepted == true }
        #expect(r2.music.openedLocations == [try #require(MusicController.stationURL(seededBy: "1730817069"))])
    }

    @Test func aPlaylistThePhoneJustAddedIsWaitedForThenPlayed() async throws {
        let r = await rig(state: "paused")
        r.companion.libraryPoll = .milliseconds(20)
        let remote = PlaylistRemote(.played(index: 59), music: r.music, notHereFirst: 3)
        r.companion.remote = remote
        var added = Self.place
        added.addedToLibrary = true
        let id = await r.relay.simulate(.playStation(seededBy: "1730817069", position: 61, title: "Idontknow", playlist: added,
                                                     repeatMode: .one, issuedAt: Date()))
        await eventually { await r.relay.ack(for: id) != nil }
        #expect(await r.relay.ack(for: id)?.accepted == true, "answered at once; the wait goes on afterwards")
        #expect(await eventually { remote.asked.count == 4 })
        #expect(await eventually { r.music.position > 60 }, "seeked to where the phone is once it plays")
        #expect(r.music.openedLocations.isEmpty, "no station")
        #expect(r.music.repeatMode == .one)
    }

    @Test func aPlaylistThatNeverArrivesIsTheStationAndAnotherCommandEndsTheWait() async throws {
        let r = await rig(state: "paused")
        r.companion.libraryPoll = .milliseconds(20)
        r.companion.librarySyncWait = 0.3
        r.companion.remote = PlaylistRemote(.notHere, music: r.music)
        var added = Self.place
        added.addedToLibrary = true
        let late = await r.relay.simulate(.playStation(seededBy: "1730817069", playlist: added, issuedAt: Date()))
        await eventually { await r.relay.ack(for: late)?.accepted == true }
        #expect(await eventually { r.music.openedLocations.first?.hasSuffix("/station/ra.1730817069") == true })

        let r2 = await rig(state: "paused")
        r2.companion.libraryPoll = .milliseconds(200)
        r2.companion.remote = PlaylistRemote(.notHere, music: r2.music)
        let waiting = await r2.relay.simulate(.playStation(seededBy: "1730817069", playlist: added, issuedAt: Date()))
        await eventually { await r2.relay.ack(for: waiting)?.accepted == true }
        let pause = await r2.relay.simulate(RemoteCommand(kind: .pause, issuedAt: Date()))
        await eventually { await r2.relay.ack(for: pause) != nil }
        try await Task.sleep(for: .milliseconds(500))
        #expect(r2.music.openedLocations.isEmpty, "the wait ended without a station")
    }

    @Test func theStationWhenTheMacHasNoSuchPlaylistOrCantPlayIt() async throws {
        for outcome in [PlaylistPlayOutcome.notHere, .failed("Music's remote protocol didn't answer")] {
            let r = await rig(state: "paused")
            let remote = PlaylistRemote(outcome, music: r.music)
            r.companion.remote = remote
            let id = await r.relay.simulate(.playStation(seededBy: "1730817069", position: 61, title: "Idontknow", playlist: Self.place,
                                                         issuedAt: Date()))
            await eventually { await r.relay.ack(for: id) != nil }
            #expect(await r.relay.ack(for: id)?.accepted == true)
            #expect(remote.asked.count == 1)
            #expect(r.music.openedLocations.first?.hasSuffix("/station/ra.1730817069") == true)
        }
    }

    @Test func theStationWhenNotConnectedToMusicOrThePlaceIsUnusable() async throws {
        let r = await rig(state: "paused")
        let id = await r.relay.simulate(.playStation(seededBy: "1730817069", playlist: Self.place, issuedAt: Date()))
        await eventually { await r.relay.ack(for: id)?.accepted == true }
        #expect(r.music.openedLocations.count == 1)
        #expect(r.companion.events.contains { $0.text.contains("not connected to Music") })

        let remote = PlaylistRemote(.played(index: 0), music: r.music)
        r.companion.remote = remote
        let broken = PlaylistPlace(name: "Road Trip", count: 3, index: 7)
        let second = await r.relay.simulate(.playStation(seededBy: "1730817069", playlist: broken, issuedAt: Date()))
        await eventually { await r.relay.ack(for: second)?.accepted == true }
        #expect(remote.asked.isEmpty)
        #expect(r.music.openedLocations.count == 2)
    }

    @Test func aValueCommandWithoutItsValueIsInvalidAndNeverReachesMusic() async throws {
        let r = await rig()
        let before = r.music.scripts.count
        for command in [RemoteCommand(kind: .seek), RemoteCommand(kind: .setVolume), RemoteCommand(kind: .selectOutput, outputID: ""),
                        RemoteCommand(kind: .playStation), RemoteCommand(kind: .playStation, catalogID: "1/../2")] {
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

    /// For the phone's Continue Listening status (16 November 2026).
    @Test func eachStateSaysWhetherTheMacIsConnectedToMusic() async throws {
        let r = await rig()
        #expect(await states(r.relay).last?.musicConnection == .notConnected)
        r.companion.remote = ConnectionRemote(forgotten: false)
        #expect(await eventually { await states(r.relay).last?.musicConnection == .connected })
        r.companion.remote = ConnectionRemote(forgotten: true)
        #expect(await eventually { await states(r.relay).last?.musicConnection == .forgotten })
        r.companion.remote = nil
        #expect(await eventually { await states(r.relay).last?.musicConnection == .notConnected })
    }

    /// Music's remote protocol whose repeat changes after the first read.
    private actor ChangingRemote: MusicRemoteReading {
        private(set) var reads = 0
        func queue(current track: MusicTrack?) async -> RemoteQueue? {
            reads += 1
            return RemoteQueue(catalogID: "1730817069", upNext: [QueuedTrack(catalogID: "1", title: "A", artist: "B", duration: 100)],
                               repeatMode: reads == 1 ? .off : .all)
        }
    }

    @Test func aRepeatChangePartWayThroughASongReachesThePhone() async throws {
        let remote = ChangingRemote()
        let r = await rig(remote: remote)
        r.companion.remoteRereadInterval = 0
        await eventually { await states(r.relay).last?.repeatMode == .off }
        #expect(await eventually { await states(r.relay).last?.repeatMode == .all }, "read again, and sent without a new song")
        #expect(await states(r.relay).last?.track?.title == (await states(r.relay).first { $0.repeatMode == .off })?.track?.title)
    }

    private struct ConnectionRemote: MusicRemoteReading {
        let forgotten: Bool
        func queue(current track: MusicTrack?) async -> RemoteQueue? { nil }
        var isForgottenByMusic: Bool { get async { forgotten } }
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
        let a = FakeMusic.Track(title: "Magic Wand", artist: "Made-Up Band", album: "Magic Wand", duration: 230, pid: "3C97D19625454E5C", artwork: FakeMusic.png(side: 800))
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
