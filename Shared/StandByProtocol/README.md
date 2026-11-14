# StandByProtocol

Shared Swift package defining the messages between the Mac companion, the relay and the
iPhone app. Foundation and CryptoKit only; iOS 17+ and macOS 14+.

- **[PROTOCOL.md](PROTOCOL.md)** — the contract: identities, revisions, commands, frames,
  and what changed from the iOS app's temporary models.
- **[Examples/](Examples/)** — one JSON file per frame and HTTP body. The tests decode and
  re-encode every one.

| File | Contents |
| --- | --- |
| `Wire.swift` | Protocol version and the JSON coders |
| `Track.swift` | `TrackMetadata`, `TrackID` |
| `Playback.swift` | `PlaybackState`, `PlaybackMessage` |
| `Commands.swift` | `CommandKind`, `RemoteCommand`, `CommandAck`, HTTP bodies |
| `Artwork.swift` | `ArtworkID`, `ArtworkDescriptor` |
| `Devices.swift` | `DeviceIdentity`, `PairedMac` |
| `Errors.swift` | `ErrorCode`, `ProtocolError`, `ConnectionStatus` |
| `Frames.swift` | `MacFrame`, `RelayFrame` |
| `Sequencing.swift` | `RevisionCounter`, `ListeningSessionTracker` |
| `Relay.swift` | Relay API bodies: pairing, push tokens, `SessionState`, `NowPlayingAttributes` |

## Tests

```bash
./scripts/test.sh
```

Runs `swift test` when a working Xcode is selected. Otherwise it compiles with the
Command Line Tools' `swiftc` directly and runs the Swift Testing suites from a small
entry point (`scripts/TestMain.swift`). That path exists because SwiftPM can't build
manifests with the damaged Command Line Tools on the authoring Mac.
