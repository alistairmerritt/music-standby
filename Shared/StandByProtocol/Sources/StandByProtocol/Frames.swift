import Foundation

// WebSocket frames between the Mac and the relay. Every frame is one JSON
// object with a `type`. Domain objects travel nested under a key named for
// them (`message`, `ack`, `command`, `artwork`, `error`); small frame-specific
// fields sit beside `type`. A frame type a peer doesn't know decodes as
// `.unknown` and should be ignored, so new frame types are additive.

/// The Mac's opening frame on every connection.
public struct Hello: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var device: DeviceIdentity

    public init(protocolVersion: Int = StandByWire.version, device: DeviceIdentity) {
        self.protocolVersion = protocolVersion
        self.device = device
    }
}

/// Frames the Mac sends.
public enum MacFrame: Equatable, Sendable {
    /// First frame on every connection. The current `state` follows at once.
    case hello(Hello)
    case state(PlaybackMessage)
    case ack(CommandAck)
    /// The Mac has stored or uploaded the image for this id.
    case artwork(ArtworkDescriptor)
    /// The companion app is quitting on purpose. Unlike a dropped socket, the
    /// relay needn't wait out a reconnect grace period.
    case goodbye(reason: String)
    case error(ProtocolError)
    case unknown(type: String)
}

/// Frames the relay sends to the Mac.
public enum RelayFrame: Equatable, Sendable {
    /// Answer to `hello`: the version the relay will speak.
    case welcome(protocolVersion: Int)
    case command(RemoteCommand)
    /// A command whose `kind` this build doesn't know. Decoded rather than
    /// dropped so the Mac can still reject it by id.
    case unsupportedCommand(id: UUID, kind: String)
    case artworkRequest(artworkID: String)
    case paired(phone: DeviceIdentity)
    case revoked(reason: String)
    case error(ProtocolError)
    case unknown(type: String)
}

// MARK: - Coding

private enum FrameKeys: String, CodingKey {
    case type, protocolVersion, device, message, ack, artwork, reason, error, command, artworkID, phone
}

private struct RawCommand: Decodable {
    var id: UUID
    var kind: String
}

extension MacFrame: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: FrameKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "hello":
            self = .hello(Hello(protocolVersion: try c.decode(Int.self, forKey: .protocolVersion),
                                device: try c.decode(DeviceIdentity.self, forKey: .device)))
        case "state": self = .state(try c.decode(PlaybackMessage.self, forKey: .message))
        case "ack": self = .ack(try c.decode(CommandAck.self, forKey: .ack))
        case "artwork": self = .artwork(try c.decode(ArtworkDescriptor.self, forKey: .artwork))
        case "goodbye": self = .goodbye(reason: try c.decode(String.self, forKey: .reason))
        case "error": self = .error(try c.decode(ProtocolError.self, forKey: .error))
        default: self = .unknown(type: type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: FrameKeys.self)
        switch self {
        case .hello(let hello):
            try c.encode("hello", forKey: .type)
            try c.encode(hello.protocolVersion, forKey: .protocolVersion)
            try c.encode(hello.device, forKey: .device)
        case .state(let message):
            try c.encode("state", forKey: .type)
            try c.encode(message, forKey: .message)
        case .ack(let ack):
            try c.encode("ack", forKey: .type)
            try c.encode(ack, forKey: .ack)
        case .artwork(let artwork):
            try c.encode("artwork", forKey: .type)
            try c.encode(artwork, forKey: .artwork)
        case .goodbye(let reason):
            try c.encode("goodbye", forKey: .type)
            try c.encode(reason, forKey: .reason)
        case .error(let error):
            try c.encode("error", forKey: .type)
            try c.encode(error, forKey: .error)
        case .unknown(let type):
            try c.encode(type, forKey: .type)
        }
    }
}

extension RelayFrame: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: FrameKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "welcome": self = .welcome(protocolVersion: try c.decode(Int.self, forKey: .protocolVersion))
        case "command":
            if let command = try? c.decode(RemoteCommand.self, forKey: .command) {
                self = .command(command)
            } else {
                // Rethrows if even the id is unreadable: then there is nothing to reject.
                let raw = try c.decode(RawCommand.self, forKey: .command)
                self = .unsupportedCommand(id: raw.id, kind: raw.kind)
            }
        case "artwork-request": self = .artworkRequest(artworkID: try c.decode(String.self, forKey: .artworkID))
        case "paired": self = .paired(phone: try c.decode(DeviceIdentity.self, forKey: .phone))
        case "revoked": self = .revoked(reason: try c.decode(String.self, forKey: .reason))
        case "error": self = .error(try c.decode(ProtocolError.self, forKey: .error))
        default: self = .unknown(type: type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: FrameKeys.self)
        switch self {
        case .welcome(let version):
            try c.encode("welcome", forKey: .type)
            try c.encode(version, forKey: .protocolVersion)
        case .command(let command):
            try c.encode("command", forKey: .type)
            try c.encode(command, forKey: .command)
        case .unsupportedCommand(let id, let kind):
            try c.encode("command", forKey: .type)
            var nested = c.nestedContainer(keyedBy: CommandKeys.self, forKey: .command)
            try nested.encode(id, forKey: .id)
            try nested.encode(kind, forKey: .kind)
        case .artworkRequest(let artworkID):
            try c.encode("artwork-request", forKey: .type)
            try c.encode(artworkID, forKey: .artworkID)
        case .paired(let phone):
            try c.encode("paired", forKey: .type)
            try c.encode(phone, forKey: .phone)
        case .revoked(let reason):
            try c.encode("revoked", forKey: .type)
            try c.encode(reason, forKey: .reason)
        case .error(let error):
            try c.encode("error", forKey: .type)
            try c.encode(error, forKey: .error)
        case .unknown(let type):
            try c.encode(type, forKey: .type)
        }
    }

    private enum CommandKeys: String, CodingKey { case id, kind }
}

// MARK: - Convenience

extension MacFrame {
    public func encoded() throws -> Data { try StandByWire.makeEncoder().encode(self) }
    public static func decode(_ data: Data) throws -> MacFrame { try StandByWire.makeDecoder().decode(MacFrame.self, from: data) }
}

extension RelayFrame {
    public func encoded() throws -> Data { try StandByWire.makeEncoder().encode(self) }
    public static func decode(_ data: Data) throws -> RelayFrame { try StandByWire.makeDecoder().decode(RelayFrame.self, from: data) }
}
