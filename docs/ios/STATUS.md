# iOS status

Last updated 8 November 2026, branch `feature/ios`.

**The iOS app has not been built with Xcode or run on a device.** The Mac it was written on has no Xcode, so nothing importing `NowPlaying` has been compiled against the real SDK. Do [DEVICE-TESTING.md](DEVICE-TESTING.md) first.

## What exists

| Area | Location |
| --- | --- |
| App (intro, pairing, status, controls, diagnostics) | `iPhoneCompanion/App/` |
| Remote media session extension | `iPhoneCompanion/NowPlayingExtension/` |
| Shared logic and mock transport | `iPhoneCompanion/StandByKit/` |
| Temporary wire models (delete when the shared protocol lands) | `StandByKit/Sources/StandByKit/Temporary/` |
| Xcode project, entitlements, extension Info.plist | `iPhoneCompanion/MusicStandBy.xcodeproj`, `iPhoneCompanion/Signing/` |

## Verification

| Item | State | How |
| --- | --- | --- |
| API names and signatures | Checked against docs | Apple's published NowPlaying documentation, not the SDK |
| `StandByKit` logic | Compiled and tested | 24 tests pass on macOS, Swift 6 language mode |
| App and extension source | Typechecked against a stand-in only | A hand-written `NowPlaying` module transcribed from the docs, macOS 26 SDK |
| `project.pbxproj` | Syntax and references only | `plutil -lint` plus a reference check; never opened in Xcode |
| Real iOS 27 SDK build | **Not done** | Requires Xcode 27 |
| Lock Screen, Control Centre, StandBy | **Not tested** | Requires an iOS 27 iPhone |
| System-issued commands reaching the extension | **Not tested** | Requires a device |
| Push tokens and APNs delivery | **Not tested** | Requires a device, paid team and APNs key |

The stand-in proves the code is internally consistent. It can't catch a place where the real SDK differs from the docs.

## What Apple's documentation establishes

- `requestToBecomeSystemPrimary()` only takes effect while the app is in the foreground, and Apple states that it doesn't guarantee the session is displayed.
- A Mac is a supported device model: `MediaDevice.DeviceType` includes `.desktop` and `.laptop`. The articles' examples are speakers, streaming sticks and TVs.
- The docs promise the Lock Screen and Control Center. StandBy appears only in WWDC26 session 312, as a general Now Playing surface and not specifically for remote sessions. **Remote sessions in StandBy are undocumented until tested.**
- Whether a remote session can hold the primary slot while nothing plays locally on the iPhone is undocumented. Test 5 covers it.

## Decisions

- App and extension use the Swift 5 language mode, so strict-concurrency differences in a framework that couldn't be compiled here don't block the first build. `StandByKit` is Swift 6.
- The extension applies each command optimistically without bumping the revision, so the next authoritative update always wins.
- Commands older than 30 seconds are dropped rather than replayed when the app wakes.
- A lower revision is accepted only if its timestamp is more than 5 seconds newer, which is how a restarted Mac appears.

## Waiting on the Mac developer

The shared protocol wasn't on `main` as of this update. When it lands, replace `Temporary/` and the mapping in `MacPlaybackAttributes+Message.swift`, then add a real `PlaybackTransport`. It would help if the protocol defined how revisions behave across a Mac restart.
