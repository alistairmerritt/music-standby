import Testing
@testable import StandByKit

@Suite struct ReminderPushTests {
    @Test func recognisesTheRemindersPayload() {
        let reminder: [AnyHashable: Any] = ["aps": ["thread-id": "mac-playing", "content-available": 1]]
        #expect(ReminderPush.isReminder(reminder))
    }

    @Test func ignoresEverythingElse() {
        #expect(!ReminderPush.isReminder(["aps": ["thread-id": "hand-back", "content-available": 1]]))
        #expect(!ReminderPush.isReminder(["aps": ["content-available": 1]]))
        #expect(!ReminderPush.isReminder([:]))
    }
}
