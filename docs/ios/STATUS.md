# iOS status

Last updated 9 November 2026, branch `feature/ios`.

**A remote media session appears in landscape StandBy on a real iPhone.** Tested by hand on 9 November 2026 on an iPhone 15 Pro running iOS 27.2, using the mock transport and a free-team build without the App Group. The remaining tests in [DEVICE-TESTING.md](DEVICE-TESTING.md) haven't been run.

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
| Install and launch on a device | Done | Free-team build on iPhone 15 Pro, iOS 27.2 |
| Now Playing metadata and controls | Working | Song and artist shown with skip and pause buttons; observed by hand |
| Landscape StandBy (test 6) | Working | Observed by hand with the mock transport |
| Generated placeholder artwork | Working | Observed by hand. PNG encoding never finished in the extension and it kept relaunching, so generated art now reaches the system as a `CGImage` |
| Real artwork passed as image data | **Not tested** | The route `ArtworkStore.resolve` uses for cached or downloaded art |
| System Primary (test 5) | Reads No | Diagnostics showed No while the session was still displayed. Cause unknown |
| Control Centre (test 3) | **Not tested** | Requires a device |
| Survival when locked for 10 minutes, or after a force-quit | **Not tested** | Requires a device |
| System-issued commands reaching the extension | Working on the phone | Tapping skip changes the track. Nothing reaches a Mac yet (audit B1) |
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
