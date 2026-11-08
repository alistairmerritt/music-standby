# Testing on an iPhone

You need a Mac with Xcode 27, an iPhone on iOS 27, and a charger that holds the phone in landscape.

## Set up

1. Install Xcode 27 and open it once to finish installing components.
2. Open `iPhoneCompanion/MusicStandBy.xcodeproj`.
3. For both the **MusicStandBy** and **MusicStandByNowPlaying** targets, open **Signing & Capabilities** and choose your team.
4. If you use a free Personal Team, delete the `aps-environment` key from `Signing/App.entitlements`. Personal Teams can't use push, and tests 1 to 6 don't need it.
5. If the bundle IDs or App Group are already taken, change them in both targets, both entitlements files and `AppGroup.identifier` in `StandByKit/Sources/StandByKit/SharedContainer.swift`.
6. Build and run on the iPhone. Report any compile errors first, because the code hasn't been built against the real SDK.

Run the logic tests with `swift test` from `iPhoneCompanion/StandByKit`.

## Get to the home screen

Tap **Continue**, then enter any six digits except `000000`, which simulates a rejected code. "Harbour Lights" appears with artwork and moving progress.

## Tests

Record the result of each one. With the app open, tap **Show in Now Playing** before starting.

| # | Do this | Expected |
| --- | --- | --- |
| 1 | Open Diagnostics | Active: Yes. No error shown. App Group: Available |
| 2 | Lock the phone | Song, artist, album, artwork, progress and controls on the Lock Screen |
| 3 | Open Control Centre | The same media tile, with the device shown as Mock Mac |
| 4 | Tap Next on the Lock Screen | The track changes to "Second Glance". Diagnostics lists Next under Commands from System |
| 5 | Check Diagnostics > System Primary, with nothing else playing | Yes. Then start audio in another app and note whether the session keeps the slot |
| 6 | Charge in landscape, locked, with StandBy enabled | **The key test.** Note whether the media view appears, with artwork, progress and working controls |

Also check that Play and Pause work, and that progress keeps moving with the app in the background.

Extension logs appear in Console.app under the subsystem `com.alistairmerritt.MusicStandBy.NowPlaying`.

## If it doesn't appear

- Check Diagnostics for an error, and that App Group shows Available.
- Confirm `MusicStandByNowPlaying.appex` is inside the app's `Extensions` folder in the built product.
- Foreground the app and tap **Refresh Now Playing**, since the primary request only counts in the foreground.
