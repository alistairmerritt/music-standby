# Testing on an iPhone

You need a Mac with Xcode 27, an iPhone on iOS 27, and a charger that holds the phone in landscape.

## Set up

1. Open `iPhoneCompanion/MusicStandBy.xcodeproj`.
2. For both the **MusicStandBy** and **MusicStandByNowPlaying** targets, open **Signing & Capabilities** and choose your team. Don't commit the team change.
3. On a free Personal Team, remove `aps-environment` and the App Group from both files in `Signing/`, and don't commit that either. Personal Teams can't use push, and `xcodebuild` can't register the group. Keep `keychain-access-groups`.
4. Turn on Developer Mode, build and run, then trust your profile under Settings > General > VPN & Device Management.

Without a relay, Debug builds use a built-in fake Mac. Tap **Continue**, then enter any six digits except `000000`, which simulates a rejected code. "Harbour Lights" appears with artwork and moving progress.

## Tests

With the app open, tap **Show in Now Playing** before starting.

| # | Do this | Expected |
| --- | --- | --- |
| 1 | Open Diagnostics | Active: Yes, no error. App Group reads Missing on a free team |
| 2 | Lock the phone | Song, artist, album, artwork, progress and controls |
| 3 | Open Control Centre | The same media tile, with the device shown as Mock Mac |
| 4 | Tap Next on the Lock Screen | The track changes to "Second Glance", with its artwork |
| 5 | Check Diagnostics > System Primary with nothing else playing, then start audio in another app | Note whether the session keeps the slot, and whether it returns when the audio stops |
| 6 | Charge in landscape, locked, with StandBy enabled | Media view with artwork, progress and working controls |
| 7 | Leave it locked for 10 minutes | Session still shown, progress moved on |
| 8 | Force-quit the app, then tap Next | Session still shown, and the control still works |

## Results

Observed by hand on an iPhone 15 Pro running iOS 27.2 with the free team and mock transport, unless noted.

| # | Result |
| --- | --- |
| 1 | App Group Missing, as expected. System Primary read No |
| 2 | Works, including artwork after a fix |
| 3 | Not yet reported |
| 4 | Track changes. Extension log shows "Second Glance" artwork accepted; appearance not yet confirmed |
| 5 | System Primary read No while the session was showing. Other audio not yet tested |
| 6 | **Works** |
| 7 | Not yet reported |
| 8 | Not yet reported |

## If it doesn't appear

- Check Diagnostics for an error.
- Confirm `MusicStandByNowPlaying.appex` is inside the app's `Extensions` folder in the built product.
- Foreground the app and tap **Refresh Now Playing**, since the primary request only counts in the foreground.

Extension logs appear in Console.app under the subsystem `com.alistairmerritt.MusicStandBy.NowPlaying`. Files the extension writes can be read over USB with `xcrun devicectl device copy from --domain-type appDataContainer --domain-identifier com.alistairmerritt.MusicStandBy.NowPlaying`.

**Don't encode images inside the extension.** PNG encoding there never finished on iOS 27.2 and the system kept relaunching the process, with no crash report.

Logic tests: `swift test` from `iPhoneCompanion/StandByKit`.
