# iOS status

Last updated 12 November 2026, branch `feature/ios`.

**Renamed to Second Chair on 11 November 2026.** Only the names people see changed (Home Screen, screens, notifications); bundle identifiers, App IDs, the push topic and the Keychain group keep `MusicStandBy`. Entries below that predate the rename use the old name.

**A real iPhone shows the Mac's Music and controls it through the deployed relay.** Since 10 November the app and extension have run against the real Mac companion and the relay on `workers.dev`, with real APNs pushes since 11 November (sections below). The first device runs, on 8 and 9 November, used the built-in mock transport: a remote media session appeared in landscape StandBy, and the extension sent HTTPS requests and read a shared Keychain item when its controls were tapped ("Observed on a physical iPhone").

## Seek, volume and output, 11 November 2026 (evening)

Three more controls, built end to end and **tried on the iPhone on 12 November** (below).

| Control | Where | Built | Verified |
| --- | --- | --- | --- |
| Drag the progress bar to a position | Lock Screen, StandBy, Control Centre, the app | `MediaCommand.seekToPosition` → `seek` with `position` | Logic tests; Mac end by hand and by harness |
| Volume slider | Lock Screen, StandBy, Control Centre, the app | `MediaDevice.Capability.absoluteVolume` → `setVolume` with `level`; sets **Music's own volume**, not the Mac's | Same |
| Choose where the Mac plays (HomePod, Apple TV, AirPods…) | **The app only**: a "Play To" picker | `selectOutput` with an `outputID` from `playback.outputs` | Same |

Why output switching is in the app and not on the Lock Screen: the NowPlaying framework's
`devices` is a display list with volume capabilities and nothing else. There is no callback
for the person picking a device, so a remote session can't offer a route picker there. Music's
own scripting does the switch (`current AirPlay devices`), so the app's picker works wherever
the phone is unlocked.

The slider sends one level per drag in the app. On the Lock Screen iOS may call the volume
capability many times during a drag; the extension sends one command at a time and keeps only
the newest level while one is in flight. A `seek` is sent once, when the drag ends. The level
shown is the Mac's: it comes back in the next state (`attributes.volume`), by push or by the
post-tap read, and the slider snaps back to the old level until it does.

**On the iPhone 15 Pro, 12 November morning** (the relay deployed with `volume`; Music mostly
paused, with the Mac's system output at 0). Driven by an XCUITest on the phone and watched from
the Mac:

| Control | Result |
| --- | --- |
| Control Centre, expanded tile, "Track position" scrubber | Dragged to 50 %: `seek` reached the extension, Music jumped 14 s → 124 s within a second, and the scrubber then followed the Mac's own position |
| Control Centre volume slider | Showed the Mac's 35 %. A drag sent two coalesced `setVolume`s (Music 35 → 49 → 69) and the slider settled at the Mac's level. Greyed out before the relay carried `volume` |
| App volume slider | 100 → 27 on the Mac in about 2 s |
| App progress bar | Works after two fixes, below: 200 s → 59 s → 87 s |
| App Play To picker | Mac → Study HomePod → Mac, twice. Music's volume became the HomePod's (11) and stayed there after switching back |

The app's progress bar needed two changes. Inside a `TimelineView`, or re-rendered by a timer
mid-drag, the slider reported the drag's start and every value but never its end, so nothing was
sent and the bar froze at the finger. The volume slider, which never re-rendered mid-drag,
was fine. The bar now pauses its clock during a drag **and** treats 600 ms of quiet values as the
end of the drag, which is when the seek is sent. Whether a finger, rather than XCUITest's drag,
delivers the end event is still unknown; either path now sends.

Not seen on the phone: the StandBy screen itself (the driver can't see a sleeping Lock Screen),
and the Lock Screen while playing. A switch is asynchronous on the Mac: Music answers at once
and the device shows as selected a few seconds later (Living Room HomePod about 3 s, Study
HomePod under 2 s), so the picker catches up on the next state. One device, the Kitchen
HomePod, is refused by Music itself with -15014, from AppleScript too; the picker then stays
where it was. 186 StandByKit tests pass; the relay's harness 38/38.

## Pushes, 11 November 2026

**Changes made at the Mac now reach a suspended phone by push.** The paid team (it kept the Personal Team's team ID), push on, built without the App Group, which isn't registered yet. iPhone 15 Pro, iOS 27.2, the deployed relay with `PUSH_MODE=apns`. "UI test" is an XCUITest that only reads Control Centre.

| Check | Result | Evidence |
| --- | --- | --- |
| Real tokens reach the relay | Push-to-start and session tokens registered on launch | Relay log |
| APNs accepts the relay's `update` pushes | `200` every time | Relay log |
| Before the fix: app suspended, Mac skips and pauses | Each push woke the extension, which aborted. Control Centre never changed | Log, crash reports |
| After the fix: app suspended 30 s, Mac skips, pauses, skips | Control Centre followed each change. The push reached the phone 1.4–3 s after the Mac command, and the extension handled it in under 0.1 s | Log, UI test |
| The extension's own `aps-environment` | Not needed: only the app has it | Log |

**Why pushes were lost.** `mediaremoted` decodes the push's `attributes` into `MacPlaybackAttributes` in the extension. That failed on the relay's timestamp (`2026-11-11T09:53:26.250Z`): a `JSONDecoder` with its default date strategy, or a property-list decoder, can't read an ISO-8601 string. NowPlaying then sends the `DecodingError` back over XPC, and NSXPC refuses it (its `userInfo` holds `CodingKey` values), so the extension aborts in `-[NSXPCEncoder _checkObject:]`. `MacPlaybackAttributes` and `SessionTrack` now read and write `timestamp` and `artworkURL` as strings themselves, whatever the decoder's settings. A failure is logged as `Couldn't decode attributes: <field>: <reason>` and thrown as `AttributesDecodingFailure`, which carries only a string. Not verified on a device: whether that error crosses XPC without the abort.

The app registered its push-to-start token 6–13 times within a second of each launch. Harmless; not looked into.

**A session started by push stays hidden.** When Music stopped and played again, the relay ended its session and sent a `start` push for a new one. The phone created it (`Session created`, `Registered session … with 1 device(s)`) and took its updates, but neither Control Centre nor the Lock Screen showed it: iOS shows only a session the app asked for while open (`requestToBecomeSystemPrimary`, which isn't available in the extension). So one session now lasts as long as the pairing. The relay keeps it when Music stops, quits or the Mac goes away, and the app keeps it on `stopped`, `not_running` and `automation_denied`, both showing the last track paused. Tested on the iPhone after opening the app once, then with it in the background: stop, play, quit Music, relaunch, play a new song, pause. Control Centre followed each within about 6 s. Not tried: whether a long-paused session stays on the Lock Screen, and the Mac asleep overnight.

**A dismissed player stays hidden until the app opens (11 November).** Swiping the player away doesn't end the session: the next `update` push still got `200`, and the extension still fetched the new track's artwork. It just stops being shown, and only the open app can ask for it back (`requestToBecomeSystemPrimary`, which the app already calls on foreground). So neither the relay nor the extension can tell a dismissed session from a visible one, and a "tap to show" notification would fire blind. The app's Now Playing section now says so. Apple has a report of push-started sessions not appearing, FB24876585 ([forum thread 847394](https://developer.apple.com/forums/thread/847394)).

**Reminders (opt-in, 11 November).** Home has a "Remind When Music Starts" toggle, off by default. Turning it on asks for notification permission (alerts only, no sound) and sends the app's push token to the relay (`PUT /v1/tokens/alert`). The relay then sends "Music playing on <Mac>", "Tap to show on your Lock Screen." when the Mac starts playing after 30 minutes without, or when it starts a new session. Each reminder replaces the last. Tapping it opens the app, which brings the player back. It is sent blind, since nothing shows whether the player is on screen, and it isn't shown while the app is open. Tapping it turns showing back on, even after Stop Showing (`activateNowPlaying()` now works before the Mac's state has arrived). `ReminderModel`, the relay calls and the tap have 8 tests. On the iPhone, with the relay's break set to 20 s: turning it on asked for permission and registered the token. After the player was dismissed (Control Centre: "Not Playing"), playing on the Mac delivered the notification, and tapping it brought the player back. A first try had used the in-app Stop Showing button instead of dismissing, which then stopped the tap from bringing it back; that was fixed and retested.

**Reminders are Time Sensitive (12 November).** In StandBy the reminder never appeared. It was an ordinary ("active") alert, and a Focus holds those back; StandBy usually runs under a Work or Sleep Focus (Home Assistant showed Work Focus on). The relay now sends it with `interruption-level: time-sensitive`, and the app has the Time Sensitive Notifications entitlement (added to the App ID by automatic provisioning). On the iPhone, Settings → Notifications → Second Chair now shows "Time Sensitive Notifications: on". The relay with it was deployed the same morning (version `eeae1bd9`). Not yet seen arriving in StandBy: that needs a 30-minute break in playback. Settings that still affect it: a Focus can turn off "Time Sensitive" for its apps; Show Previews "When Unlocked" hides the text in StandBy; StandBy's own "Show Notifications".

**Getting ready for TestFlight (12 November).** `iPhoneCompanion/scripts/archive.sh` archives and exports with the relay host built in, and checks the export is signed for production pushes with Time Sensitive (DEVICE-TESTING, "TestFlight and the App Store"). The Release configuration compiles with the host in its `Info.plist` (unsigned build). **First TestFlight build uploaded the same day**: build 202611121125 (version 0.1), archived and exported by the script, which checked the package carries `aps-environment` `production`, Time Sensitive, the relay host, and the Now Playing extension (in `Extensions/`, as an ExtensionKit extension) with the App Group. The distribution certificate is cloud-managed, so none was added to the keychain. `ITSAppUsesNonExemptEncryption` is `NO` (HTTPS only), so App Store Connect doesn't ask about export compliance. Installed from TestFlight on the iPhone 15 Pro over the Xcode build: the pairing carried over (same Keychain group), and with the phone locked and the app asleep, a skip on the Mac reached the Lock Screen by push, so the relay found the production environment by itself. On that first skip the artwork didn't come with the title; it did from the next song on (relay README, the TestFlight paragraph). The App Group was then registered for both App IDs, so builds no longer need temporary entitlements: a Debug build with the committed ones signed for the device. Production push tokens are handled by the relay, which retries a sandbox `BadDeviceToken` in production and remembers the answer per pairing; no app change was needed.

**A session without a track still shows (11 November).** To hide a long-paused player without ending the session, a test relay pushed the session with its track removed 45 s after a pause. Control Centre and the Lock Screen (checked by hand) both kept an empty player, with Previous, Play and Next but no song, rather than hiding it. When Music played again, the song came back by itself, with no need to open the app. Not adopted: an empty player is no better than the paused song, and ending the session would hide the next song until the app is opened. My XCUITest driver can't see the Lock Screen's player while the phone is locked and the screen asleep, even while playing, so Lock Screen checks are by hand.

**Apple Watch (by hand, 11 November).** The session appears in the Watch's Now Playing, and its skip buttons work. The Digital Crown does nothing: the session's `MediaDevice` declares no capabilities. NowPlaying offers `absoluteVolume` and `relativeVolume` if Mac volume control is wanted.

**Artwork on the phone (11 November).** After the Mac's artwork fixes, songs on the phone showed no artwork at all. In the phone's log, iOS suspends the extension about a second after each update and doesn't wake it again just to get an image. A fetch that started only when the system asked for the image stalled mid-way and finished on the next song. Three changes, one in each part:

- **Mac:** uploads a song's artwork before sending the state that names it, waiting at most 2 s.
- **Extension:** starts fetching the artwork as soon as an update arrives, instead of waiting for the system to ask. The song's content id now includes the artwork id (`<track id>#<16 hex>`), because iOS asks for an item's artwork when the item first appears, not when artwork is added to it later.
- **Relay:** sends the same update again 0.7 s after one with new artwork. That wakes the extension again once the image is cached.

The extension logs each request for the image ("asked for at WxH, cached: …", "handed over"). One song in the log: update at 20:59:02.287, fetch started at once, the system asked at 171×171 77 ms later, the image was cached in 508 ms and handed over, and the follow-up update came at 03.326. The artwork then showed on the phone (by hand). Checked over a handful of songs, not a long session.

## What exists

| Area | Location |
| --- | --- |
| App (intro, pairing, status, controls, diagnostics) | `iPhoneCompanion/App/` |
| Remote media session extension | `iPhoneCompanion/NowPlayingExtension/` |
| Shared logic, `AppModel`, session lifecycle | `iPhoneCompanion/StandByKit/` |
| Relay client, credentials, command path | `StandByKit/Sources/StandByKit/Relay/` |
| Mock transport for development | `StandByKit/Sources/StandByKit/Mock/` |
| Wire protocol | `Shared/StandByProtocol/`, merged from `main` |
| Relay endpoints the client assumes | [RELAY-CLIENT-CONTRACT.md](RELAY-CLIENT-CONTRACT.md) |

## Observed on a physical iPhone

iPhone 15 Pro, iOS 27.2, free Personal Team, mock transport, connected by USB. "Hand" means reported by the person holding the phone. "Log" means read from the phone.

| Behaviour | Result | Evidence |
| --- | --- | --- |
| Landscape StandBy | Works | Hand |
| Song details, skip and pause on the Lock Screen | Work | Hand |
| Placeholder artwork | Shows | Hand |
| Control Centre | Works | Hand |
| Locked for 10 minutes | Session stays, progress moves | Hand |
| Force-quit the app | Session stays, Next still works | Hand |
| Lock Screen Next with the new code | Track changes, time moves | Hand, at `4b306d5` plus temporary test logging |
| Shared Keychain, free team | App wrote an item, extension read it, including at each tap | Log |
| HTTPS from a command handler | 120 to 250 ms, status 200, on each tap | Log |
| Extension memory | **Hard 6 MB limit** | Log |
| Extension network | iOS marks it "network restriction applied". HTTPS still worked. What it restricts is unknown | Log |
| PNG encoding in the extension | Never finished, and the process was replaced. Likely the memory limit; not confirmed | Log |
| Artwork sizes iOS requests | 88, 156, 171 and 807 points or pixels | Log |

**Another app playing audio**

| Situation | Result |
| --- | --- |
| Our session off, Music plays | Music appears |
| Music playing, then Show in Now Playing | Our session takes over |
| Our session showing, then Music starts | Music takes over |
| Music stops | Music's last track stays. Our session does not return by itself |

Once, on an older build, neither app appeared when audio started. That wasn't reproduced with the newer build.

**System Primary** read No once while the session was on screen. A later check reported no errors, but the value wasn't recorded. It hasn't affected StandBy or the Lock Screen.

**Installing over a live session leaves a broken extension.** iOS relaunched the extension from the outgoing copy of the app at the moment of install. That process had its file writes denied, failed every command, and survived ending and restarting the session. Separately, a launch 5 s after an install failed, while one about 50 s later worked. Could affect real app updates. Not yet tested whether a phone restart clears it. Seen again on 11 November: an extension launched 3 s before an install finished kept the old code (its debug dylib had the old build's UUID), and crashed on the new app's attributes. Once it had crashed, the next launch ran the new code.

## Still to test on a device

- Real-sized artwork as image data. Only a 100-pixel image has run through that route with logging, and the 600 and 1200-pixel test was blocked by the stale process above.
- The Time Sensitive reminder arriving in StandBy under a Focus.
- Seek and volume from the StandBy screen and the locked Lock Screen. The XCUITest driver can't see either, so these are by hand.
- A finger, rather than XCUITest's drag, ending a drag on the app's progress bar.
- HTTPS and Keychain without USB, and over cellular.

## Passes automated tests

`swift test` from `iPhoneCompanion/StandByKit`: **186 tests**, macOS, Xcode 27.2 (run again on 12 November). `Shared/StandByProtocol`: 59 tests on this branch. `feature/macos` has 60: its copy also has the song-ID change from 11 November (`pid:<id>-<12 hex>`), which the phone doesn't need, since it only compares IDs for equality. The extension's artwork prefetch has no automated test.

| Area | Covers |
| --- | --- |
| Session lifecycle (audit B3) | Ends on stop, Music quit, refused Automation, unpair, deliberate disconnect, and a drop past 60 s. Pause, read errors and brief drops keep it. Push tokens go with it |
| Event loop (audit C3) | Survives cancellation and restart, and reports the true connection state afterwards |
| Failed activation (audit C4) | Retries on the next update and on foreground, with the newest state |
| Relay client | Pairing, commands, acks and failures, tokens, reconnection, revocation, revision ordering |
| Real networking | Against a loopback server: round trip, redirects refused, response size cap, timeouts |
| Extension command path (audit B1, B2) | Sends directly; no optimistic change; mock only on the Debug route; an unreadable Keychain never falls back to the mock |
| Artwork (audit C1) | PNG and JPEG, size limits, HTTPS and relay-host only, missing artwork |

Deliberately reintroducing 14 of these bugs made the tests fail. One further change, removing an early check that the size cap also covers, did not. These tests run on macOS and don't exercise `NowPlaying`.

## Compiles only

App and extension build for the iOS 27.2 device SDK, Debug and Release. `RemoteSessionController` and the views have no automated tests.

## Blocked

- **App Group.** Register `group.com.alistairmerritt.MusicStandBy` on the developer site (Identifiers → App Groups) and add it to both App IDs; `xcodebuild` can't. Until then, build with temporary entitlements that leave it out. Only the mock route's command log and Diagnostics use it.
- **TestFlight and distribution.** Not started. Builds signed by the paid team now last a year.
- **Still to try by hand:** a locked phone and StandBy with pushes, and late artwork arriving by push.

Pairing with a real Mac, Lock Screen controls reaching it, artwork from the relay and the relay endpoints were done on 10 November; see [RELAY-CLIENT-CONTRACT.md](RELAY-CLIENT-CONTRACT.md).

## Decisions

- App and extension use the Swift 5 language mode. `StandByKit` is Swift 6.
- The relay route never changes the screen optimistically. Only the Debug mock does.
- Debug builds use the mock unless a relay credential exists. Release builds never use it.
- 60 s reconnect grace, 1.5 s command timeout, 5 s foreground polling and the extension's 1 MB and 800-pixel artwork limits are judgement calls. None are measured.
- A paused session is not ended on the phone. The proposal gives the 15-minute timeout to the relay.
- The session doesn't try to reclaim the Lock Screen when local audio stops. Apple only honours that request from the foreground, so the app re-requests it each time it opens.
