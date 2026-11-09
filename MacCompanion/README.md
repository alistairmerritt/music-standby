# Mac companion

A SwiftUI menu-bar app that watches Apple Music on this Mac, publishes its state in the
shared protocol (`Shared/StandByProtocol`), and applies playback commands from the
iPhone. Today it talks to a built-in mock relay; the WebSocket relay is not built.

What is verified, and how, is in **[STATUS.md](STATUS.md)**.

## Layout

| Path | What |
| --- | --- |
| `Sources/CompanionCore/Music/` | `MusicController` (AppleScript, main thread), `MusicMonitor` (notifications, lifecycle, poll), `MusicScripts`, `ArtworkProcessor` |
| `Sources/CompanionCore/Companion/` | `Companion` (the engine), `PlaybackPublisher` (snapshots → `PlaybackMessage`), `CompanionStore` |
| `Sources/CompanionCore/Transport/` | `CompanionTransport` and `MockRelayTransport` |
| `Sources/MusicStandBy/` | The menu-bar app: `MenuBarExtra`, menu content, Launch at Login |
| `Sources/msbctl/` | Command-line driver for checking CompanionCore against the real Music.app |
| `Tests/CompanionCoreTests/` | Swift Testing suites, using a fake Music behind the script-runner seam |
| `Prototypes/MusicProbe/` | The spike this started from, kept as it was |

## Build and test

With Xcode selected (verified with Xcode 27.2, macOS 27.2 SDK):

```bash
swift test
```

```bash
scripts/build.sh
```

`build.sh` compiles with `swiftc` and assembles `build/Music StandBy.app`, ad-hoc signed,
plus `.build/swiftc/msbctl`. Without a working Xcode it falls back to the Command Line
Tools with a workaround for their broken module map (see `scripts/toolchain.sh`).
SwiftPM alone can't make an `.app` with an `Info.plist`, which is why the script exists.
An Xcode app project is still to do.

Each rebuild changes the ad-hoc signature, so macOS asks for Automation permission again.
Launch at Login needs the app in `/Applications`.

## Checking against the real Music.app

```bash
.build/swiftc/msbctl snapshot
```

```bash
.build/swiftc/msbctl artwork --out /tmp/art
```

```bash
.build/swiftc/msbctl watch 60
```

`watch` runs the whole companion against the mock relay and prints every frame as wire
JSON. Type `play`, `pause`, `next`, `previous`, `stale`, `dup`, `seek` or `drop` to
simulate the phone. `control` changes playback directly. None of these launch Music.

## Rules the code depends on

- **NSAppleScript runs on the main thread only.** Off it, scripts took 8–158 s or hung
  (STATUS.md). `MusicController` is `@MainActor`; `AppleScriptRunner` asserts it.
- **Never launch Music.** A process check, then an in-script `is running` guard, then a
  2 s hold after any "Stopped" notification and a 3 s hold after a launch, because Apple
  Events sent while Music is quitting relaunch it.
- **`playerInfo` is a trigger only.** Every change is re-read through AppleScript.
- **Revisions only rise**, across restarts: seeded from `max(persisted, Unix ms)`.
