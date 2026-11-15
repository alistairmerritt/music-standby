# iPhone companion

The Second Chair iPhone app (iOS 27). It shows Music playing on the paired Mac as the
iPhone's own Now Playing, sends the controls back through the relay, and moves the music
between the Mac and Apple Music on the phone.

What is verified on a real iPhone, and how, is in **[docs/ios/STATUS.md](../docs/ios/STATUS.md)**.

## Layout

| Path | What |
| --- | --- |
| `App/` | The app: `MusicStandByApp`, `AppEnvironment` (assembles the parts), `Notifications` (push token, reminder and Continue from iPhone notifications, the background wake), `PhoneMusicPlayer` (Apple Music on the phone, through MediaPlayer and MusicKit), `RemoteSessionController` |
| `App/Views/` | Intro, pairing, the home screen (Now Playing, Continue Listening, the reminder, the Mac) and Diagnostics |
| `App/Shortcuts/` | The Shortcuts actions and App Shortcuts. Each goes straight to the relay through `MacRemote`, so it runs without opening the app |
| `App/StationProbe.swift` | Development builds only: tries a queue followed by a station from the Mac, without anyone at the phone (below) |
| `NowPlayingExtension/` | The remote media session extension: what iOS shows on the Lock Screen and in StandBy, and the commands from it |
| `StandByKit/` | The logic, as a Swift package with its own tests: `AppModel`, the session lifecycle, `Handover` (Continue on iPhone and on Mac), `HandBackResponder` (Continue from iPhone), the relay client, credentials, reminders, and a mock Mac for development |
| `Signing/` | Info.plists and entitlements for both targets |
| `scripts/archive.sh` | Archives for TestFlight, with the relay host built in |

## Build and test

```bash
cd StandByKit && swift test
```

```bash
xcodebuild build -project MusicStandBy.xcodeproj -scheme MusicStandBy -configuration Debug \
  -destination generic/platform=iOS -derivedDataPath build/dd -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=$(head -1 ~/.config/second-chair/team-id) \
  MSB_RELAY_HOST=$(head -1 ~/.config/second-chair/relay-host)
```

```bash
xcrun devicectl device install app --device <udid> build/dd/Build/Products/Debug-iphoneos/MusicStandBy.app
```

The relay host is a build setting, empty in the repository, so it never enters this public
repository. Without it, a Debug build runs on the built-in mock Mac.

**Before installing over a running copy, tap Stop Showing in the app.** Otherwise the Now
Playing extension keeps running from the old build, its commands fail, and only a restart
of the phone clears it. Tap Show in Now Playing about a minute after the install.

## TestFlight

```bash
scripts/archive.sh --upload
```

It archives with the relay host built in, refuses an archive whose App Intent descriptions
name an Apple product (App Store Connect rejects them, ITMS-90626), checks the export's
entitlements and uploads. The build number is the time, `yyyymmddHHMM`.

## What the app needs from the Apple Developer account

On the App ID `com.alistairmerritt.MusicStandBy` and its extension:

- Push Notifications, and Time Sensitive Notifications.
- The App Group `group.com.alistairmerritt.MusicStandBy` and a shared Keychain group, both
  targets.
- The **MusicKit** app service (App Services tab), for the station after a short queue.
  It isn't an entitlement, so nothing in `Signing/` shows it.

## Trying things on the phone from the Mac

- `idevicesyslog -u <udid>` (libimobiledevice) reads the phone's log over USB. The Shortcuts
  actions log their steps under the `Shortcuts` category.
- `StationProbe`, in development builds only:
  `xcrun devicectl device process launch --device <udid> --terminate-existing com.alistairmerritt.MusicStandBy -- -stationProbePlaying`.
  The `--` matters. The phone must be unlocked. It replaces Apple Music's queue on the phone
  and plays briefly.
