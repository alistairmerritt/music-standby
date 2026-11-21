import Foundation
import Testing
@testable import StandByKit

@Suite struct WidgetSnapshotTests {
    private func attributes(_ title: String, playing: Bool) -> MacPlaybackAttributes {
        MacPlaybackAttributes(id: "s1", macName: "Studio Mac", revision: 1, isPlaying: playing, elapsedTime: 0, timestamp: Date(),
                              track: SessionTrack(id: title, title: title, artist: "Artist", album: "Album", duration: 200, artworkID: nil),
                              canGoNext: true, canGoPrevious: true)
    }

    @Test func onIPhoneStaysWhileTheMacIsPausedOnTheSameSong() {
        var previous = WidgetSnapshot.from(attributes("Low Sun", playing: true), previous: nil)
        previous.onIPhone = true
        let next = WidgetSnapshot.from(attributes("Low Sun", playing: false), previous: previous)
        #expect(next.onIPhone)
    }

    @Test func theMacPlayingEndsOnIPhone() {
        var previous = WidgetSnapshot.from(attributes("Low Sun", playing: false), previous: nil)
        previous.onIPhone = true
        #expect(!WidgetSnapshot.from(attributes("Low Sun", playing: true), previous: previous).onIPhone)
    }

    @Test func anotherSongEndsOnIPhone() {
        var previous = WidgetSnapshot.from(attributes("Low Sun", playing: false), previous: nil)
        previous.onIPhone = true
        #expect(!WidgetSnapshot.from(attributes("Small Hours", playing: false), previous: previous).onIPhone)
    }

    @Test func theClockAloneIsNotADifference() {
        let a = WidgetSnapshot(macName: "Mac", title: "A", updatedAt: Date(timeIntervalSince1970: 1))
        let b = WidgetSnapshot(macName: "Mac", title: "A", updatedAt: Date(timeIntervalSince1970: 2))
        #expect(!b.looksDifferent(from: a))
        #expect(WidgetSnapshot(macName: "Mac", title: "B").looksDifferent(from: a))
    }

    @Test func savesAndLoads() {
        let suite = "widget-snapshot-tests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let snapshot = WidgetSnapshot(macName: "Mac", title: "A", artist: "B", macPlaying: true)
        WidgetSnapshot.publish(snapshot, to: defaults)
        #expect(WidgetSnapshot.load(from: defaults) == snapshot)
        WidgetSnapshot.markOnIPhone(true, in: defaults)
        #expect(WidgetSnapshot.load(from: defaults)?.onIPhone == true)
        #expect(WidgetSnapshot.load(from: defaults)?.macPlaying == false)
    }
}
