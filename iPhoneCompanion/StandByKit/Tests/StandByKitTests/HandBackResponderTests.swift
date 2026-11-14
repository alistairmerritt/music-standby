import Foundation
import Testing
@testable import StandByKit

/// Continue from iPhone, asked for at the Mac: what the phone does with the
/// relay's push or notification. Added 12 November 2026.
@MainActor
@Suite struct HandBackResponderTests {
    private let base = Date(timeIntervalSince1970: 2_000_000)

    private func state(_ playback: PlaybackMessage?) -> SessionState {
        SessionState(sessionID: "s1", mac: PairedMac(id: "a", name: "Studio Mac"), macConnected: true, playback: playback, attributes: nil)
    }

    private func song(_ catalogID: String, state: PlaybackState) -> PlaybackMessage {
        var track = track()
        track.catalogID = catalogID
        return message(state: state, track: track)
    }

    private func setup(phone: PhoneNowPlaying?, clock: MutableClock? = nil)
        -> (HandBackResponder, FakeRelay, Reports, FakePhoneMusic) {
        let relay = FakeRelay(state(song("1102359994", state: .paused)))
        let reports = Reports()
        let music = FakePhoneMusic()
        music.current = phone
        let suite = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        let now = clock ?? MutableClock(base)
        let responder = HandBackResponder(defaults: suite, makeRemote: { MacRemote(client: relay, sleep: { _ in }) },
                                          report: { await reports.add($0) }, now: { now.now })
        return (responder, relay, reports, music)
    }

    @Test func aWakeHandsBackAndReportsEachStep() async {
        let (responder, relay, reports, phone) = setup(phone: PhoneNowPlaying(catalogID: "1102359994", position: 61, isPlaying: true))
        await relay.setNext(state(song("1102359994", state: .playing)))
        let request = HandBackRequest(requestID: UUID(), expiresAt: base.addingTimeInterval(120))
        #expect(await responder.respond(to: request, via: .wake, player: phone) == .done)
        #expect(await reports.all.map(\.status) == [.working, .done])
        #expect(await reports.all.allSatisfy { $0.requestID == request.requestID })
        #expect(await relay.sent.map(\.command.kind) == [.seek, .play])
        #expect(phone.pauses == 1)
    }

    @Test func aLateWakeIsIgnoredButALateTapIsNot() async {
        let clock = MutableClock(base)
        let (responder, relay, reports, phone) = setup(phone: PhoneNowPlaying(catalogID: "1102359994", position: 61, isPlaying: true), clock: clock)
        await relay.setNext(state(song("1102359994", state: .playing)))
        let request = HandBackRequest(requestID: UUID(), expiresAt: base.addingTimeInterval(120))
        clock.advance(600)
        #expect(await responder.respond(to: request, via: .wake, player: phone) == nil)
        #expect(await reports.all.isEmpty)
        #expect(await responder.respond(to: request, via: .tap, player: phone) == .done)
    }

    @Test func eachRequestIsActedOnOnce() async {
        let (responder, relay, reports, phone) = setup(phone: PhoneNowPlaying(catalogID: "1102359994", position: 61, isPlaying: true))
        await relay.setNext(state(song("1102359994", state: .playing)))
        let request = HandBackRequest(requestID: UUID(), expiresAt: base.addingTimeInterval(120))
        #expect(await responder.respond(to: request, via: .wake, player: phone) == .done)
        #expect(await responder.respond(to: request, via: .tap, player: phone) == nil)
        #expect(await reports.all.count == 2)
    }

    @Test func saysWhyItCouldnt() async {
        let (nothing, _, nothingReports, idle) = setup(phone: nil)
        #expect(await nothing.respond(to: HandBackRequest(requestID: UUID(), expiresAt: base.addingTimeInterval(60)), via: .tap, player: idle) == .nothingPlaying)
        #expect(await nothingReports.all.map(\.status) == [.working, .nothingPlaying])

        let (elsewhere, _, _, other) = setup(phone: PhoneNowPlaying(catalogID: "999", position: 5, isPlaying: true))
        #expect(await elsewhere.respond(to: HandBackRequest(requestID: UUID(), expiresAt: base.addingTimeInterval(60)), via: .tap, player: other) == .notInQueue)

        let reports = Reports()
        let unpaired = HandBackResponder(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!,
                                         makeRemote: { throw TransportError.notPaired }, report: { await reports.add($0) })
        #expect(await unpaired.respond(to: HandBackRequest(requestID: UUID(), expiresAt: .distantFuture), via: .tap, player: FakePhoneMusic()) == .failed)
        #expect(await reports.all.map(\.status) == [.working, .failed])
    }

    @Test func readsTheRequestFromAPushPayloadOnly() {
        let id = UUID()
        let payload: [AnyHashable: Any] = [
            "aps": ["content-available": 1],
            "handBack": ["requestID": id.uuidString, "expiresAt": "2026-11-12T10:02:00.000Z"],
        ]
        let request = HandBackResponder.request(from: payload)
        #expect(request?.requestID == id)
        #expect(request?.expiresAt == StandByWire.parseDate("2026-11-12T10:02:00.000Z"))
        #expect(HandBackResponder.request(from: ["aps": ["alert": "Music playing"]]) == nil)
        #expect(HandBackResponder.request(from: ["handBack": ["requestID": "nope"]]) == nil)
    }
}

actor Reports {
    private(set) var all: [HandBackStatusReport] = []
    func add(_ report: HandBackStatusReport) { all.append(report) }
}
