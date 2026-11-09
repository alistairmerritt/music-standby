# iOS status

Last updated 9 November 2026, branch `feature/ios`.

**A remote media session appears in landscape StandBy on a real iPhone, and the new extension sends HTTPS requests and reads a shared Keychain item when its controls are tapped.** All of this used the built-in mock transport. Nothing has talked to a real Mac or relay.

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

iPhone 15 Pro, iOS 27.2, free Personal Team, mock transport, connected by USB. "Hand" means reported by the person holding the phone. "Log" means read from the phone.

| Behaviour | Result | Evidence |
| --- | --- | --- |
| Landscape StandBy | Works | Hand |
| Song details, skip and pause on the Lock Screen | Work | Hand |
| Placeholder artwork | Shows | Hand |
| Control Centre | Works | Hand |
| Locked for 10 minutes | Session stays, progress moves | Hand |
| Force-quit the app | Session stays, Next still works | Hand |
| Lock Screen Next with the new code | Track changes, time moves | Hand, at `4b306d5` plus temporary test logging |
| Shared Keychain, free team | App wrote an item, extension read it, including at each tap | Log |
| HTTPS from a command handler | 120 to 250 ms, status 200, on each tap | Log |
| Extension memory | **Hard 6 MB limit** | Log |
| Extension network | iOS marks it "network restriction applied". HTTPS still worked. What it restricts is unknown | Log |
| PNG encoding in the extension | Never finished, and the process was replaced. Likely the memory limit; not confirmed | Log |
| Artwork sizes iOS requests | 88, 156, 171 and 807 points or pixels | Log |

**Another app playing audio**

| Situation | Result |
| --- | --- |
| Our session off, Music plays | Music appears |
| Music playing, then Show in Now Playing | Our session takes over |
| Our session showing, then Music starts | Music takes over |
| Music stops | Music's last track stays. Our session does not return by itself |

Once, on an older build, neither app appeared when audio started. That wasn't reproduced with the newer build.

**System Primary** read No once while the session was on screen. A later check reported no errors, but the value wasn't recorded. It hasn't affected StandBy or the Lock Screen.

**Installing over a live session leaves a broken extension.** iOS relaunched the extension from the outgoing copy of the app at the moment of install. That process had its file writes denied, failed every command, and survived ending and restarting the session. Separately, a launch 5 s after an install failed, while one about 50 s later worked. Could affect real app updates. Not yet tested whether a phone restart clears it.

## Still to test on a device

- Real-sized artwork as image data. Only a 100-pixel image has run through that route with logging, and the 600 and 1200-pixel test was blocked by the stale process above.
- Everything committed after `4b306d5`.
- HTTPS and Keychain without USB, and over cellular.

## Passes automated tests

`swift test` from `iPhoneCompanion/StandByKit`: **134 tests**, macOS, Xcode 27.2. `Shared/StandByProtocol`: 49 tests.

| Area | Covers |
| --- | --- |
| Session lifecycle (audit B3) | Ends on stop, Music quit, refused Automation, unpair, deliberate disconnect, and a drop past 60 s. Pause, read errors and brief drops keep it. Push tokens go with it |
| Event loop (audit C3) | Survives cancellation and restart, and reports the true connection state afterwards |
| Failed activation (audit C4) | Retries on the next update and on foreground, with the newest state |
| Relay client | Pairing, commands, acks and failures, tokens, reconnection, revocation, revision ordering |
| Real networking | Against a loopback server: round trip, redirects refused, response size cap, timeouts |
| Extension command path (audit B1, B2) | Sends directly; no optimistic change; mock only on the Debug route; an unreadable Keychain never falls back to the mock |
| Artwork (audit C1) | PNG and JPEG, size limits, HTTPS and relay-host only, missing artwork |

Deliberately reintroducing 14 of these bugs made the tests fail. One further change, removing an early check that the size cap also covers, did not. These tests run on macOS and don't exercise `NowPlaying`.

## Compiles only

App and extension build for the iOS 27.2 device SDK, Debug and Release. `RemoteSessionController` and the views have no automated tests.

## Blocked

**Solely by Apple Developer Program membership**

- APNs: start, update and end pushes, and token delivery.
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
- 60 s reconnect grace, 1.5 s command timeout, 5 s foreground polling and the extension's 1 MB and 800-pixel artwork limits are judgement calls. None are measured.
- A paused session is not ended on the phone. The proposal gives the 15-minute timeout to the relay.
- The session doesn't try to reclaim the Lock Screen when local audio stops. Apple only honours that request from the foreground, so the app re-requests it each time it opens.
