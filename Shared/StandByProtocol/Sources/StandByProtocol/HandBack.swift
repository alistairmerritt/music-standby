import Foundation

// Continue from iPhone, asked for at the Mac (12 November 2026). The Mac
// can't see what the phone plays and can't pause it, so the relay wakes the
// phone's app, which runs its own Continue on Mac: the Mac skips to the
// phone's song, seeks to the phone's position and plays, and the phone
// pauses. See docs/relay/API-v1.md §14.
//
//   Mac → relay   hand-back-request {requestID}
//   relay → phone a background push; after 5 s without an answer, a notification
//   phone → relay POST /v1/hand-back/status {requestID, status}
//   relay → Mac   hand-back-status {requestID, status}, for each step

/// Where a hand-back has got to. An open set, like `ErrorCode`: a Mac that
/// doesn't know a status shows nothing for it.
public struct HandBackStatus: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
    public var description: String { rawValue }

    // From the relay.
    /// The relay sent the phone a background push.
    public static let asked: HandBackStatus = "asked"
    /// The phone didn't answer the background push in time, so the relay
    /// showed a notification; a tap on it hands back.
    public static let notified: HandBackStatus = "notified"
    /// The relay has no way to reach the phone: no device token, or APNs refused.
    public static let unreachable: HandBackStatus = "unreachable"

    // From the phone.
    /// The phone's app is awake and handing back.
    public static let working: HandBackStatus = "working"
    /// The Mac is playing the phone's song and the phone has paused.
    public static let done: HandBackStatus = "done"
    /// Nothing is loaded in Apple Music on the phone.
    public static let nothingPlaying: HandBackStatus = "nothing_playing"
    /// The phone's song isn't the Mac's current song or in its Up Next.
    public static let notInQueue: HandBackStatus = "not_in_queue"
    /// The Mac refused a step or didn't start the song in time.
    public static let failed: HandBackStatus = "failed"

    /// Nothing more will come for this request.
    public var isFinal: Bool {
        [.done, .nothingPlaying, .notInQueue, .failed, .unreachable].contains(self)
    }
}

/// `POST /v1/hand-back/status`: the phone's progress on one request.
public struct HandBackStatusReport: Codable, Equatable, Sendable {
    public var requestID: UUID
    public var status: HandBackStatus

    public init(requestID: UUID, status: HandBackStatus) {
        self.requestID = requestID
        self.status = status
    }
}

/// What a hand-back push carries for the app, under the payload's
/// `handBack` key beside `aps`.
public struct HandBackRequest: Codable, Equatable, Sendable {
    public var requestID: UUID
    /// A background push that wakes the app later than this is ignored: music
    /// moving minutes after the click would be a surprise. A tap on the
    /// notification is acted on whenever it comes; the tap is the request.
    public var expiresAt: Date

    public init(requestID: UUID, expiresAt: Date) {
        self.requestID = requestID
        self.expiresAt = expiresAt
    }

    /// The payload key.
    public static let payloadKey = "handBack"
    /// The notification's thread and collapse id.
    public static let threadID = "hand-back"
    /// The notification's category. The app gives it a Continue on Mac
    /// button that hands back without opening the app. Apple Watch shows the
    /// button too, which matters in StandBy: a phone there is locked, so its
    /// notifications go to a watch on the wrist (added 13 November 2026).
    public static let categoryID = "hand-back"
}

/// `PUT /v1/tokens/device`: the app's own APNs device token, for hand-back
/// pushes. Sent whenever the app has one, whatever its reminder setting;
/// a background push needs no notification permission.
public struct DeviceTokenRegistration: Codable, Equatable, Sendable {
    public var token: String

    public init(token: String) {
        self.token = token
    }
}

/// Why the phone sent a command, when the Mac should know more than its kind.
/// An open set; a Mac that doesn't know a reason just runs the command.
public struct CommandReason: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
    public var description: String { rawValue }

    /// The `pause` Continue on iPhone sends once the song plays on the phone.
    /// The Mac then knows the phone has its music, and offers Continue from iPhone.
    public static let continueOnPhone: CommandReason = "continue_on_phone"
}
