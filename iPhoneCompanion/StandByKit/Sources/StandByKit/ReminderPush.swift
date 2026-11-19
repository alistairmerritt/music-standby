import Foundation

/// The relay's "Music playing on <Mac>" reminder (`REMINDER_ID` in
/// Relay/src/push.ts). It carries `content-available`, so it wakes the app in
/// the background as well as showing the alert.
public enum ReminderPush {
    public static let thread = "mac-playing"

    /// True for the reminder's remote notification payload.
    public static func isReminder(_ userInfo: [AnyHashable: Any]) -> Bool {
        (userInfo["aps"] as? [String: Any])?["thread-id"] as? String == thread
    }
}
