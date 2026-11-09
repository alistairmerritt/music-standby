# Testing on an iPhone

You need a Mac with Xcode 27, an iPhone on iOS 27, and a charger that holds the phone in landscape.

## Set up

1. Open `iPhoneCompanion/MusicStandBy.xcodeproj`.
2. For both the **MusicStandBy** and **MusicStandByNowPlaying** targets, open **Signing & Capabilities** and choose your team. Don't commit the team change.
3. On a free Personal Team, remove `aps-environment` and the App Group from both files in `Signing/`, and don't commit that either. Personal Teams can't use push, and `xcodebuild` can't register the group. Keep `keychain-access-groups`.
4. Turn on Developer Mode, build and run, then trust your profile under Settings > General > VPN & Device Management.

**Before installing a new build, tap Stop Showing, and open the app about a minute after the install.** Installing over a live session left an extension running from the old copy of the app, with every command failing.

Without a relay, Debug builds use a built-in fake Mac. Tap **Continue**, then enter any six digits except `000000`, which simulates a rejected code. "Harbour Lights" appears with artwork and moving progress.

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
