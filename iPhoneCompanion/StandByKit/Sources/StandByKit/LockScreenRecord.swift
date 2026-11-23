import Foundation

/// A lasting record of what happened around the Lock Screen player: the
/// reminder arriving, the app waking for it, the Show in Now Playing action's
/// runs and what it gave back, and the app coming to the front. It outlives the
/// app's process, unlike Diagnostics' log, so a run that went wrong can be
/// read afterwards in Settings › Diagnostics (23 November 2026: the reminder's
/// shortcut worked only sometimes, and nothing said which step failed).
public enum LockScreenRecord {
    public struct Entry: Codable, Equatable, Identifiable, Sendable {
        public var date: Date
        public var message: String
        public var id: String { "\(date.timeIntervalSince1970)-\(message)" }

        public init(date: Date, message: String) {
            self.date = date
            self.message = message
        }
    }

    static let key = "lockScreenRecord"
    /// Enough for a few days of reminders without growing.
    static let limit = 120

    /// The App Group's defaults, so every launch of the app sees the same record.
    public static var defaults: UserDefaults { UserDefaults(suiteName: AppGroup.identifier) ?? .standard }

    public static func add(_ message: String, at date: Date = Date(), in defaults: UserDefaults = LockScreenRecord.defaults) {
        var all = entries(in: defaults)
        all.insert(Entry(date: date, message: message), at: 0)
        if all.count > limit { all.removeLast(all.count - limit) }
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: key) }
    }

    /// Newest first.
    public static func entries(in defaults: UserDefaults = LockScreenRecord.defaults) -> [Entry] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    public static func clear(in defaults: UserDefaults = LockScreenRecord.defaults) {
        defaults.removeObject(forKey: key)
    }

    /// The whole record as text, oldest first, for pasting into a message.
    public static func text(in defaults: UserDefaults = LockScreenRecord.defaults) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_AU_POSIX")
        formatter.dateFormat = "d MMM HH:mm:ss"
        return entries(in: defaults).reversed().map { "\(formatter.string(from: $0.date))  \($0.message)" }.joined(separator: "\n")
    }
}
