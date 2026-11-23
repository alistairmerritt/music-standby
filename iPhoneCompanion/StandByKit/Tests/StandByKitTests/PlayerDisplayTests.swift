import Foundation
import Testing
@testable import StandByKit

@Suite struct PlayerDisplayTests {
    private func defaults() -> UserDefaults {
        let name = "PlayerDisplayTests-\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }

    @Test func automaticByDefault() {
        #expect(PlayerDisplay.current(in: defaults()) == .automatic)
    }

    @Test func theOldSwitchTurnedOffMeansNowPlaying() {
        let d = defaults()
        d.set(false, forKey: PlayerDisplay.legacyCardKey)
        #expect(PlayerDisplay.current(in: d) == .nowPlaying)
        d.set(true, forKey: PlayerDisplay.legacyCardKey)
        #expect(PlayerDisplay.current(in: d) == .automatic)
    }

    @Test func aChoiceWinsOverTheOldSwitch() {
        let d = defaults()
        d.set(false, forKey: PlayerDisplay.legacyCardKey)
        PlayerDisplay.liveActivity.save(in: d)
        #expect(PlayerDisplay.current(in: d) == .liveActivity)
    }

    @Test func whatEachUses() {
        #expect(PlayerDisplay.automatic.usesNowPlaying && PlayerDisplay.automatic.usesLiveActivity)
        #expect(PlayerDisplay.nowPlaying.usesNowPlaying && !PlayerDisplay.nowPlaying.usesLiveActivity)
        #expect(!PlayerDisplay.liveActivity.usesNowPlaying && PlayerDisplay.liveActivity.usesLiveActivity)
    }
}
