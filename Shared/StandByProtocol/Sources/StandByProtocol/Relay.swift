import Foundation

// HTTP bodies and frames for the relay API. The contract, with every endpoint,
// status code and sequence, is docs/relay/API-v1.md. All of these are additive
// to protocol version 1.

// MARK: - Pairing

/// `POST /v1/pairings` (Mac, no credentials). Creates the Mac's pairing record.
public struct PairingCreateRequest: Codable, Equatable, Sendable {
    public var device: DeviceIdentity
    public init(device: DeviceIdentity) { self.device = device }
}

/// `201` from `POST /v1/pairings`. The Mac stores `macToken` in its Keychain.
public struct PairingCreateResponse: Codable, Equatable, Sendable {
    public var pairingID: String
    /// Opaque bearer credential. Shown once; the relay keeps only a hash.
    public var macToken: String
    public init(pairingID: String, macToken: String) {
        self.pairingID = pairingID
        self.macToken = macToken
    }
}

/// `201` from `POST /v1/pairing/code` (Mac). A new code replaces any earlier one.
public struct PairingCodeResponse: Codable, Equatable, Sendable {
    /// Six ASCII digits.
    public var code: String
    public var expiresAt: Date
    public init(code: String, expiresAt: Date) {
        self.code = code
        self.expiresAt = expiresAt
    }
}

/// `POST /v1/pairing/claim` (phone, no credentials).
public struct PairingClaimRequest: Codable, Equatable, Sendable {
    public var code: String
    public var phone: DeviceIdentity
    public init(code: String, phone: DeviceIdentity) {
        self.code = code
        self.phone = phone
    }
}

/// `202` from `POST /v1/pairing/claim`. Nothing is granted until the Mac approves.
public struct PairingClaimResponse: Codable, Equatable, Sendable {
    public var claimID: String
    /// Bearer credential for polling this claim, and nothing else.
    public var claimSecret: String
    public var expiresAt: Date
    /// So the phone can show which Mac it is waiting for.
    public var mac: PairedMac
    public init(claimID: String, claimSecret: String, expiresAt: Date, mac: PairedMac) {
        self.claimID = claimID
        self.claimSecret = claimSecret
        self.expiresAt = expiresAt
        self.mac = mac
    }
}

/// `200` from `GET /v1/pairing/claim/{claimID}`. `approved` carries the phone's
/// credential exactly once; the claim is gone after that.
public struct PairingClaimStatus: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case pending, approved, denied
    }

    public var status: Status
    public var pairingID: String?
    public var phoneToken: String?
    public var mac: PairedMac?

    public init(status: Status, pairingID: String? = nil, phoneToken: String? = nil, mac: PairedMac? = nil) {
        self.status = status
        self.pairingID = pairingID
        self.phoneToken = phoneToken
        self.mac = mac
    }
}

/// Relay → Mac, in a `pair-request` frame: a phone has typed the code and is
/// waiting for the person at the Mac to allow it.
public struct PairRequest: Codable, Equatable, Sendable {
    public var claimID: String
    public var phone: DeviceIdentity
    public var expiresAt: Date
    public init(claimID: String, phone: DeviceIdentity, expiresAt: Date) {
        self.claimID = claimID
        self.phone = phone
        self.expiresAt = expiresAt
    }
}

// MARK: - Push tokens and sessions

/// `PUT /v1/tokens/start` (phone): the push-to-start token, as hex.
public struct PushToStartTokenRegistration: Codable, Equatable, Sendable {
    public var token: String
    public init(token: String) { self.token = token }
}

/// `PUT /v1/tokens/session` (phone or extension): one session's update token, as hex.
public struct SessionPushTokenRegistration: Codable, Equatable, Sendable {
    public var sessionID: String
    public var token: String
    public init(sessionID: String, token: String) {
        self.sessionID = sessionID
        self.token = token
    }
}

/// `POST /v1/session/end` (phone).
public struct SessionEndRequest: Codable, Equatable, Sendable {
    public var sessionID: String
    public init(sessionID: String) { self.sessionID = sessionID }
}

/// The `attributes` the relay puts in a `nowplaying` push, and returns from
/// `GET /v1/session`. Field for field the iOS app's `MacPlaybackAttributes`,
/// which is what the system decodes them into.
public struct NowPlayingAttributes: Codable, Equatable, Sendable, Identifiable {
    public struct Track: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var artist: String
        public var album: String
        public var duration: TimeInterval
        /// Always present. `""` when the track has no artwork, because the iOS
        /// type declares it non-optional and a push that fails to decode is lost.
        public var artworkID: String
        /// A capability URL on the relay; absent when there is no artwork.
        public var artworkURL: URL?

        public init(id: String, title: String, artist: String, album: String, duration: TimeInterval, artworkID: String, artworkURL: URL? = nil) {
            self.id = id
            self.title = title
            self.artist = artist
            self.album = album
            self.duration = duration
            self.artworkID = artworkID
            self.artworkURL = artworkURL
        }
    }

    /// The relay's session id. Not the Mac's listening session.
    public var id: String
    public var macName: String
    public var revision: UInt64
    public var isPlaying: Bool
    public var elapsedTime: TimeInterval
    public var timestamp: Date
    public var track: Track?
    public var canGoNext: Bool
    public var canGoPrevious: Bool
    /// `PlaybackMessage.volume`, copied through. Lets the Lock Screen's
    /// volume slider show Music's level. Absent from an older relay.
    public var volume: Double?

    public init(id: String, macName: String, revision: UInt64, isPlaying: Bool, elapsedTime: TimeInterval, timestamp: Date,
                track: Track?, canGoNext: Bool, canGoPrevious: Bool, volume: Double? = nil) {
        self.id = id
        self.macName = macName
        self.revision = revision
        self.isPlaying = isPlaying
        self.elapsedTime = elapsedTime
        self.timestamp = timestamp
        self.track = track
        self.canGoNext = canGoNext
        self.canGoPrevious = canGoPrevious
        self.volume = volume
    }
}

/// `200` from `GET /v1/session` (phone). What the relay knows right now.
public struct SessionState: Codable, Equatable, Sendable {
    /// The current Now Playing session, or nil when there is none.
    public var sessionID: String?
    public var mac: PairedMac
    public var macConnected: Bool
    /// The Mac's last state frame, exactly as received.
    public var playback: PlaybackMessage?
    /// What a push for the current session carries. Nil without a session.
    public var attributes: NowPlayingAttributes?

    public init(sessionID: String?, mac: PairedMac, macConnected: Bool, playback: PlaybackMessage?, attributes: NowPlayingAttributes?) {
        self.sessionID = sessionID
        self.mac = mac
        self.macConnected = macConnected
        self.playback = playback
        self.attributes = attributes
    }
}

// MARK: - Error codes the relay adds

extension ErrorCode {
    public static let unauthorized: ErrorCode = "unauthorized"
    public static let invalidRequest: ErrorCode = "invalid_request"
    public static let notFound: ErrorCode = "not_found"
    public static let payloadTooLarge: ErrorCode = "payload_too_large"
    /// The command named a session that is not the current one.
    public static let sessionMismatch: ErrorCode = "session_mismatch"
    /// There is no current session to send a command to.
    public static let noSession: ErrorCode = "no_session"
    public static let pairingCodeInvalid: ErrorCode = "pairing_code_invalid"
    public static let claimExpired: ErrorCode = "claim_expired"
    public static let claimDenied: ErrorCode = "claim_denied"
}
