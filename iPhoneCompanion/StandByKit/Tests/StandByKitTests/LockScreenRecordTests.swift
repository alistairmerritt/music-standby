import Foundation
import Testing
@testable import StandByKit

@Suite struct LockScreenRecordTests {
    private func fresh() -> UserDefaults {
        let name = "LockScreenRecordTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func keepsEntriesNewestFirstAcrossReads() {
        let d = fresh()
        LockScreenRecord.add("Reminder arrived", at: Date(timeIntervalSince1970: 100), in: d)
        LockScreenRecord.add("Show in Now Playing ran", at: Date(timeIntervalSince1970: 101), in: d)
        #expect(LockScreenRecord.entries(in: d).map(\.message) == ["Show in Now Playing ran", "Reminder arrived"])
    }

    @Test func keepsOnlyTheLatest() {
        let d = fresh()
        for i in 0..<(LockScreenRecord.limit + 5) {
            LockScreenRecord.add("entry \(i)", at: Date(timeIntervalSince1970: Double(i)), in: d)
        }
        let all = LockScreenRecord.entries(in: d)
        #expect(all.count == LockScreenRecord.limit)
        #expect(all.first?.message == "entry \(LockScreenRecord.limit + 4)")
    }

    @Test func textIsOldestFirstAndClearEmpties() {
        let d = fresh()
        LockScreenRecord.add("first", at: Date(timeIntervalSince1970: 100), in: d)
        LockScreenRecord.add("second", at: Date(timeIntervalSince1970: 200), in: d)
        let lines = LockScreenRecord.text(in: d).split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].hasSuffix("first") && lines[1].hasSuffix("second"))
        LockScreenRecord.clear(in: d)
        #expect(LockScreenRecord.entries(in: d).isEmpty)
    }
}
