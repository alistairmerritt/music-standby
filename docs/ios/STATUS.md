# iOS status

Last updated 9 November 2026, branch `feature/ios`.

**A remote media session appears in landscape StandBy on a real iPhone.** That was shown with the mock transport. The reliability fixes and relay client below pass automated tests but have **not yet been run on a phone**. No part of this has talked to a real Mac or relay.

## What exists

| Area | Location |
| --- | --- |
| App (intro, pairing, status, controls, diagnostics) | `iPhoneCompanion/App/` |
| Remote media session extension | `iPhoneCompanion/NowPlayingExtension/` |
| Shared logic, `AppModel`, session lifecycle | `iPhoneCompanion/StandByKit/` |
| Relay client, credentials, command path | `StandByKit/Sources/StandByKit/Relay/` |
| Mock transport for development | `StandByKit/Sources/StandByKit/Mock/` |
| Wire protocol | `Shared/StandByProtocol/`, merged from `main` |
| Relay endpoints the client assumes | [RELAY-CLIENT-CONTRACT.md](RELAY-CLIENT-CONTRACT.md) |

## Observed on a physical iPhone

iPhone 15 Pro, iOS 27.2, free Personal Team, mock transport. All from the build at commit `a824478` and earlier debug builds of it, so these predate the reliability and relay work.

| Behaviour | Result | Evidence |
| --- | --- | --- |
| Installs and launches | Works | Hand test |
| Song details on the Lock Screen | Works | Hand test |
| Skip and pause buttons | Appear and respond | Hand test; the extension logged each tap |
| Landscape StandBy (test 6) | Works | Hand test |
| Generated placeholder artwork | Shows | Hand test, after a fix |
| PNG encoding inside the extension | **Never finishes** | Log: it stopped at `CGImageDestinationFinalize` and the process was relaunched. Avoid it there |
| Image data handed to the system | Accepted without error | Extension log only. Whether it looked right is unconfirmed |
| System Primary | Read No while the session was showing | Hand test. Cause unknown |

Other device tests are in [DEVICE-TESTING.md](DEVICE-TESTING.md).

## Passes automated tests

`swift test` from `iPhoneCompanion/StandByKit`: **120 tests**, macOS, Xcode 27.2. `Shared/StandByProtocol`: 49 tests. Nine deliberately reintroduced bugs were each caught.

| Area | Covers |
| --- | --- |
| Session lifecycle (audit B3) | Ends on stop, Music quit, refused Automation, unpair, deliberate disconnect, and a drop past 60 s. Pause, read errors and brief drops keep it. Push tokens go with it |
| Event loop (audit C3) | Survives cancellation and restart, and reports the true connection state afterwards |
| Failed activation (audit C4) | Retries on the next update and on foreground, with the newest state |
| Relay client | Pairing, commands, acks and failures, tokens, reconnection, revocation, revision ordering, against scripted HTTP |
| Extension command path (audit B1, B2) | Sends directly; no optimistic change; mock only on the Debug route; an unreadable Keychain never falls back to the mock |
| Artwork (audit C1) | PNG and JPEG, size limits, HTTPS and relay-host only, missing artwork |

These cover logic, on macOS. They do not exercise `NowPlaying` or the Keychain.

## Compiles only

App and extension build for the iOS 27.2 device SDK, Debug and Release. They sign with the free team once the App Group and push entitlements are removed. `RemoteSessionController` and the views have no tests.

## Assumptions still to check on a device

- The extension can make an HTTPS call from a locked phone, and the system waits for it.
- `KeychainCredentialStore` works, and the extension can read what the app wrote. The free team's profile allows the shared group, and the app signs with it, but it hasn't run.
- Real album-art data, at real sizes, renders.
- The new lifecycle behaves as tested once it talks to the real `NowPlaying` framework.

## Blocked

**Solely by Apple Developer Program membership**

- APNs: start, update and end pushes, and whether tokens are issued at all.
- Updating a locked phone. A session can only change while the app is open until then.
- App Group. Only the mock route's command log and Diagnostics use it, so the relay path doesn't need it.
- Builds lasting more than 7 days, TestFlight and distribution.

**Solely by the unfinished relay**

- Pairing with a real Mac, and Lock Screen controls reaching it.
- Artwork from the relay.
- Confirming [the endpoints](RELAY-CLIENT-CONTRACT.md), which are still assumptions.

## Decisions

- App and extension use the Swift 5 language mode. `StandByKit` is Swift 6.
- The relay route never changes the screen optimistically. Only the Debug mock does.
- Debug builds use the mock unless a relay credential exists. Release builds never use it.
- 60 s reconnect grace, 1.5 s command timeout and 5 s foreground polling are judgement calls from the relay proposal. None are measured.
- A paused session is not ended on the phone. The proposal gives the 15-minute timeout to the relay.
