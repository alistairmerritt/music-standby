# iOS status

Last updated 9 November 2026, branch `feature/ios`.

**The iOS app builds against the real iOS 27.2 SDK but has not been run on a device.** Whether a remote session appears in StandBy is still unknown. Do [DEVICE-TESTING.md](DEVICE-TESTING.md) next.

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
| `StandByKit` logic | Compiled and tested | 24 of 24 tests pass with `swift test`, Xcode 27.2 toolchain (Swift 6.4.2), macOS |
| App and extension source | Compiled | Clean device build, iOS 27.2 SDK, Xcode 27.2; no compiler warnings |
| `project.pbxproj` | Builds | `xcodebuild`; the extension embeds at `MusicStandBy.app/Extensions/` |
| Signing, free Personal Team | Partial | Signs with the push and App Group entitlements removed. With the App Group left in, `xcodebuild` fails: the issued profile has an empty group list, so the group was never registered |
| App Group on a device | **Not tested** | Needs the group registered, then a device |
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
