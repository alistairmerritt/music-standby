# Testing on an iPhone

You need a Mac with Xcode 27, an iPhone on iOS 27, and a charger that holds the phone in landscape.

## Set up

1. Open `iPhoneCompanion/MusicStandBy.xcodeproj`.
2. For both the **MusicStandBy** and **MusicStandByNowPlaying** targets, open **Signing & Capabilities** and choose your team. Don't commit the team change.
3. On a free Personal Team, remove `aps-environment` and the App Group from both files in `Signing/`, and don't commit that either. Personal Teams can't use push, and `xcodebuild` can't register the group. Keep `keychain-access-groups`. On the paid team nothing needs removing: the App Group was registered for both App IDs on 12 November.
4. Turn on Developer Mode, build and run, then trust your profile under Settings > General > VPN & Device Management.

**Before installing a new build, tap Stop Showing, and open the app about a minute after the install.** Installing over a live session left an extension running from the old copy of the app, with every command failing.

Without a relay, Debug builds use a built-in fake Mac. Tap **Continue**, then enter any six digits except `000000`, which simulates a rejected code. "Harbour Lights" appears with artwork and moving progress.

## TestFlight and the App Store

```bash
iPhoneCompanion/scripts/archive.sh
```

```bash
iPhoneCompanion/scripts/archive.sh --upload
```

`archive.sh` archives the Release build with the relay host built in, exports an App Store
Connect package and checks it carries `aps-environment` `production` and Time Sensitive
notifications. `--upload` sends it to App Store Connect for TestFlight instead. A plain
Product → Archive in Xcode leaves `MSB_RELAY_HOST` empty, so that build couldn't pair.
The script reads the team ID and relay host from `MSB_TEAM_ID` and `MSB_RELAY_HOST`, or from
`~/.config/second-chair/team-id` and `relay-host`, outside the repository. Build numbers are
the time (`yyyymmddHHMM`) unless `MSB_BUILD_NUMBER` says otherwise.

Before the first archive:
1. **The App Group** is registered and enabled for both App IDs (12 November; done by
   choosing the paid team in Xcode, then `xcodebuild -allowProvisioningUpdates`). Both
   development profiles now carry it, and a build with the committed entitlements signs.
   With it, the app and the extension share their artwork cache and command log, which no
   relay build had done before, so check a build on the phone before inviting anyone.
2. For `--upload`, create the app in App Store Connect with the bundle ID
   `com.alistairmerritt.MusicStandBy`.

The first export makes an Apple Distribution certificate and App Store profiles through
automatic signing. TestFlight builds get **production** push tokens. The relay finds that
out by itself: a token the sandbox refuses with `BadDeviceToken` is tried in production, and
the environment that works is kept for the pairing (relay README, "APNs status").

## With the relay

The relay's host comes from the `MSB_RELAY_HOST` build setting, which the repository leaves empty. Pass it on the command line, or set it in Xcode without committing it:

```
xcodebuild … MSB_RELAY_HOST=<relay host> build
```

1. On the Mac: `defaults write com.alistairmerritt.MusicStandBy.Mac relayURL https://<relay host>`, then launch the menu-bar app from `feature/macos` (`MacCompanion/scripts/build.sh`).
2. Play something in Music. The relay only opens a session while Music is playing.
3. On the Mac, choose **Pair iPhone…** from the menu-bar icon. A six-digit code appears.
4. On the iPhone, enter the code. The app says it is waiting for your Mac.
5. On the Mac, click **Allow** in the menu.
6. The iPhone shows the song. Tap **Show in Now Playing**.

Without APNs, the Lock Screen can't change while the app isn't open: a command tapped there still reaches the Mac, and the screen catches up when the app is next opened. With pushes (paid team, relay `PUSH_MODE=apns`), changes at the Mac reach a suspended app's session within about 3 s.

| # | Do this | Expected |
| --- | --- | --- |
| R1 | Pair as above | Waiting screen, then the Mac's song |
| R2 | In the app, tap Pause, Play, Next and Previous | Music on the Mac does the same; the app follows within about a second |
| R3 | Lock the phone and tap Pause, then Play | Music pauses and resumes. The Lock Screen may not change |
| R4 | Locked, tap Next, then Previous | Music skips and goes back. The Lock Screen may not change |
| R5 | In StandBy, tap Pause, Play and Next | As R3 and R4 |
| R6 | Open the app after R3–R5 | It shows what the Mac is playing |
| R7 | Check the artwork in the app and on the Lock Screen | The album's own artwork |
| R8 | Locked or in StandBy, drag the progress bar to about two minutes | Music on the Mac jumps there; the bar follows within about 3 s |
| R9 | Locked or in StandBy, move the volume slider | Music's own volume on the Mac changes (not the Mac's system volume); the slider settles at the Mac's level |
| R10 | In the app, choose a HomePod under Play To, then the Mac again | Music plays to that device alone, then back. The picker follows the Mac |

R8–R10 were added on 11 November 2026 and run from Control Centre and the app on 12 November
(see STATUS.md); the Lock Screen and StandBy themselves are still to be checked by hand. Before
R9, note Music's volume on the Mac: switching output in R10 sets it to the device's own level.

## Tests

With the app open, tap **Show in Now Playing** before starting.

| # | Do this | Expected | Result on iPhone 15 Pro, iOS 27.2 |
| --- | --- | --- | --- |
| 1 | Open Diagnostics | Active: Yes, no error. App Group reads Missing on a free team | No errors |
| 2 | Lock the phone | Song, artist, album, artwork, progress and controls | Works |
| 3 | Open Control Centre | The same media tile, with the device shown as Mock Mac | Works |
| 4 | Tap Next on the Lock Screen | The track changes to "Second Glance", with its artwork | Works |
| 5 | Check Diagnostics > System Primary with nothing else playing | Note the value | No once; later value not recorded |
| 6 | Charge in landscape, locked, with StandBy enabled | Media view with artwork, progress and working controls | **Works** |
| 7 | Leave it locked for 10 minutes | Session still shown, progress moved on | Works |
| 8 | Force-quit the app, then tap Next | Session still shown, and the control still works | Works |
| 9 | Start audio in Music | Note what the Lock Screen shows | Music takes over |
| 10 | Stop the audio | Note whether the session returns | It doesn't; Music's last track stays |

Results are from the mock transport with the phone on USB. See [STATUS.md](STATUS.md) for how each was observed.

## If it doesn't appear

- Check Diagnostics for an error.
- Confirm `MusicStandByNowPlaying.appex` is inside the app's `Extensions` folder in the built product.
- Foreground the app and tap **Refresh Now Playing**, since the primary request only counts in the foreground.
- If the time is frozen and buttons flip with no effect, the extension isn't running properly. See the install warning above.

## Reading what happened

Extension logs appear in Console.app under the subsystem `com.alistairmerritt.MusicStandBy.NowPlaying`. Over USB, `idevicesyslog` from `libimobiledevice` shows why an extension failed; look for `mediaremoted`, `MRDNowPlayingSessionServer` and `runningboardd`. `xcrun devicectl device info processes` doesn't reliably list the extension.

**Inside the extension:** iOS allows 6 MB of memory. Don't encode images there. PNG encoding never finished and the process was replaced, with no crash report.

Logic tests: `swift test` from `iPhoneCompanion/StandByKit`.
