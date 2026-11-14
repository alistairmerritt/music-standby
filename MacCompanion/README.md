# Mac companion

A SwiftUI menu-bar app that watches Apple Music on this Mac, publishes its state in the
shared protocol (`Shared/StandByProtocol`), and applies playback commands from the
iPhone. Today it talks to a built-in mock relay; the WebSocket relay is not built.

What is verified, and how, is in **[STATUS.md](STATUS.md)**.

## Layout

| Path | What |
| --- | --- |
| `Sources/CompanionCore/Music/` | `MusicController` (an actor on its own queue), `RawEventRunner` (raw Apple Events by PID), `MusicProcess` (finding Music without events), `MusicMonitor` (notifications, lifecycle, poll), `MusicScripts` (the AppleScript reference), `ArtworkProcessor`, `CatalogArtwork` (art Music doesn't have) |
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

`build.sh` compiles with `swiftc` and assembles `build/Second Chair.app`, signed with your
Apple Development identity (ad-hoc if there is none, or with `MSB_SIGN_IDENTITY=-`), plus
`.build/swiftc/msbctl`. Without a working Xcode it falls back to the Command Line Tools with
a workaround for their broken module map (see `scripts/toolchain.sh`).
SwiftPM alone can't make an `.app` with an `Info.plist`, which is why the script exists.
An Xcode app project is still to do.

With a development identity, Automation and Keychain approvals survive rebuilds. An ad-hoc
signature changes with every build, so macOS asks for both again.
Launch at Login needs the app in `/Applications`.

**The relay.** `build.sh` writes the relay host into the app's `Info.plist` as `MSBRelayHost`,
from `MSB_RELAY_HOST` or the first line of `~/.config/second-chair/relay-host`. That file is
outside every checkout, so the host never enters this public repository, and the script
doesn't print it. The app uses `https://<host>`. `relayURL` in its defaults still overrides
it, for a development relay (`defaults write com.alistairmerritt.MusicStandBy.Mac relayURL
http://127.0.0.1:8787`); with neither, it runs on the built-in mock. See `RelayEndpoint`.

**Continue on iPhone.** The menu's Continue on iPhone section pairs the companion with
Music as a remote (Music's sidebar, Devices, a 4-digit code). After that every state carries
the song's Apple Music catalogue ID and Up Next, which the iPhone app uses to carry on in
Apple Music there. `msbctl remote pair FILE` makes a test pairing, and
`msbctl remote GUID SERVICE-NAME` reads the queue with it. See STATUS.

## Release

```bash
scripts/release.sh --check
```

```bash
scripts/release.sh
```

`release.sh` builds the app optimised (`-O`), signs it with a Developer ID Application
certificate, the hardened runtime and a secure timestamp, has Apple notarise it, staples the
ticket and zips it to `build/release/Second-Chair-<version>.zip` for GitHub Releases. It
uploads and publishes nothing. The release app is built in `build/release`, leaving
`build/Second Chair.app` alone: macOS ties Automation and Keychain approvals to the
signature, so a Developer ID copy is a new app to it, and running one asks for both again. `--check` only checks the three things it needs, which are
set up once:

1. A **Developer ID Application** certificate. Only the team's Account Holder can make one:
   Xcode → Settings → Accounts → the team → Manage Certificates → + → Developer ID Application.
2. **notarytool credentials** in the keychain, under the profile name `SecondChair`
   (`MSB_NOTARY_PROFILE` picks another):
   `xcrun notarytool store-credentials SecondChair --apple-id <Apple ID> --team-id <team ID>`.
   It asks for an app-specific password from account.apple.com.
3. The **relay host**, as above.

The version comes from `CFBundleShortVersionString` in `Resources/Info.plist`; raise it and
`CFBundleVersion` before each release. The build is arm64 only, which is every Mac that runs
macOS 27; `LSMinimumSystemVersion` says 14.0, but nothing has run below macOS 27.

## Artwork

Music's own artwork comes first. Music often has none for streamed songs that aren't in the
library, so for those the companion looks the song up once in Apple's public catalogue (the
iTunes Search API, `CatalogArtwork.swift`), sending the artist, the title and the Mac's
storefront. It uses a result only when the title and artist match and the album or the
length (within 3 s) does too. To use Music's artwork only:

```bash
defaults write com.alistairmerritt.MusicStandBy.Mac catalogArtwork -bool false
```

`msbctl watch --no-catalog` does the same for a run.

## Checking against the real Music.app

```bash
.build/swiftc/msbctl snapshot
```

```bash
.build/swiftc/msbctl artwork --out /tmp/art
```

```bash
.build/swiftc/msbctl compare
```

```bash
.build/swiftc/msbctl watch 60
```

`compare` reads through raw Apple Events and through the AppleScript reference and checks
the two return the same output. `watch` runs the whole companion against the mock relay
and prints every frame as wire JSON. Type `play`, `pause`, `next`, `previous`, `stale`,
`dup`, `seek` or `drop` to simulate the phone, or `read` to ask for a read. `control`
changes playback directly. None of these launch Music.

## Rules the code depends on

- **Apple Events go to Music's process id, off the main thread.** `RawEventRunner` sends
  raw events with `NSAppleEventDescriptor.sendEvent` from `MusicController`'s own serial
  queue. NSAppleScript is main-thread only (off it, scripts took 8–158 s or hung) and
  addresses Music by name, which relaunches a quitting Music. `AppleScriptRunner` stays
  as the reference that `msbctl compare` checks against.
- **Never launch Music.** A process check (`MusicProcess`: a remembered PID checked with
  the kernel, because NSRunningApplication briefly lists no Music every few seconds),
  then every event addressed by PID. An event that reaches a Music that has quit fails;
  it can't start a new one. No hold after "Stopped" is needed any more.
- **Don't read a Music that isn't up yet.** It answers about 4 s after its process
  starts. Reads wait while the process is younger than that, and 3 s after NSWorkspace's
  launch notification.
- **`playerInfo` is a trigger only.** Every change is re-read through AppleScript.
- **Revisions only rise**, across restarts: seeded from `max(persisted, Unix ms)`.
