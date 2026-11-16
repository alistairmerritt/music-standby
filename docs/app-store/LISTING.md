# App Store listing: Second Chair for iPhone

Everything to fill in on App Store Connect for version 1.0, in the order its pages ask for it.
Written 16 November 2026, against the app's code and madewithmerritt.com/second-chair/. The
first build for review is TestFlight 202611161444, version 1.0.

Contact details for App Review (name, phone, email) aren't kept here: this repository is
public.

## Before the app can go on sale

- **Agreements, Tax and Banking:** a paid app needs the Paid Apps Agreement, with tax forms
  and a bank account, all active. Until then, App Store Connect won't let a paid app go live.
- **App Store Small Business Program:** enrol before sales start. Apple's commission is then
  15% instead of 30%.
- **Relay:** deploy PR #21 (`npm run deploy` in `Relay/`). The privacy policy relies on it.
- **Privacy policy:** the Second Chair section live at `https://madewithmerritt.com/privacy/#second-chair`.
- **Website:** at launch, `/second-chair/` and the guide still say "free beta" and
  "TestFlight". They'll need the App Store link and price instead (part 3).

## App Information

| Field | Value |
| --- | --- |
| Name | Second Chair *(already set on the app record made for TestFlight; check it reads "Second Chair")* |
| Subtitle (30) | Your Mac's music on iPhone |
| Primary language | English (Australia), to match the app's spelling ("recognises", "catalogue") |
| Category | Music; secondary: Utilities |
| Content rights | Contains third-party content: **Yes**, and has the rights: **Yes**. It shows the song names and artwork from the person's own Music app and Apple Music, for them alone, as a remote does. It ships no music or artwork of its own; the demo's songs and covers are invented |
| Age rating | Answer **None** or **No** to every question: no violence, no sexual content, no gambling, no contests, no medical topics, no unrestricted web access, no user-generated content, no messaging, no advertising, no parental controls. Result: **4+** |

## Pricing and Availability

- **Price:** US$2.99. Apple sets the matching price in each other country.
- **Availability:** all countries, unless you want otherwise.
- **iPhone and iPad apps on Apple silicon Macs:** **untick**. On a Mac the app has no Lock
  Screen or StandBy, and Second Chair for Mac does the Mac side.
- **Apple Vision Pro:** **untick**, for the same reason.

## App Privacy

**Privacy Policy URL:** `https://madewithmerritt.com/privacy/#second-chair`

"Do you or your third-party partners collect data from this app?" **Yes.** Two types, both
matching `PrivacyInfo.xcprivacy`:

| Type | What it is here | Purposes | Linked to the user | Tracking |
| --- | --- | --- | --- | --- |
| **Usage Data → Product Interaction** | What's playing on the Mac, as the relay holds it for the phone; the controls tapped; the song sent by Continue on Mac. Apple's examples for this type include "music listening data" | App Functionality only | **No** | **No** |
| **Identifiers → Device ID** | The random install ID the app makes, and its push tokens | App Functionality only | **No** | **No** |

Nothing else: no contact info, location, contacts, health, financial info, browsing or search
history, diagnostics or crash logs of our own. Apple's own crash reports don't count.

"Not linked" holds because there are no accounts: the app makes up its own random IDs, sends
the phone's name only as "iPhone", and nothing is ever matched to a person. One thing to know:
the relay also holds the **Mac's** name, which often includes the owner's name ("Alistair's
MacBook Pro"). That's collected by the Mac app, which isn't on the App Store, so it isn't part
of these answers, but the privacy policy mentions it.

## Version 1.0

### Promotional text (170)

```
Music playing on your Mac, on your iPhone's Lock Screen and in StandBy. Play, pause and skip from there, and the music keeps playing on your Mac.
```

### Description (4000)

```
Second Chair puts the music playing on your Mac on your iPhone's Lock Screen and in StandBy, and lets you control it from there.

It needs Second Chair for Mac, a free download from madewithmerritt.com, running on your Mac alongside the Music app.

Press it here. It happens there.
• See the song, artwork and progress from your Mac on your iPhone's Lock Screen, in StandBy, in Control Centre and on your Apple Watch.
• Play, pause, skip and scrub. The music keeps playing on your Mac.
• Change the volume of Music on your Mac from the app.
• When the song changes on your Mac, your iPhone keeps up by itself.
• Swiped the player away? An optional reminder brings it back when the music starts again.

Take your music with you. Then bring it back.
• Continue on iPhone picks up the song from your Mac in Apple Music on your iPhone, from the same point, with your Up Next queue.
• Continue on Mac sends what your iPhone is playing back to your Mac.
• Continue Listening works with Shortcuts, so your music can move between devices without you lifting a finger.

Requirements
• An iPhone with iOS 27.
• A Mac with Apple silicon and macOS 27, running Music and Second Chair for Mac.
• An internet connection on both. One iPhone per Mac.
• Continue Listening needs an Apple Music subscription on your iPhone, and a one-time connection on your Mac.

No accounts, no ads and no tracking.
```

### Keywords (100)

```
remote,lock screen,standby,now playing,controller,menu bar,desk,queue,playback,continue,companion
```

97 characters. Words already in the name and subtitle (second, chair, mac, music, iphone) are
left out: Apple searches those anyway. No Apple trademarks, such as Apple Music, iTunes,
AirPlay or HomePod. Keywords may not use them.

### URLs

| Field | Value |
| --- | --- |
| Support URL | `https://madewithmerritt.com/second-chair/` (its Contact link is the support route) |
| Marketing URL | `https://madewithmerritt.com/second-chair/` |

### Copyright

```
2026 Alistair Merritt
```

### Version release

**Manually release this version**, so the website can change from beta to App Store on the
same day.

## App Review Information

- **Sign-in required:** No.
- **Contact:** your name, phone and email.
- **Attachment:** the review video below, if it's ready.

### Notes (4000)

```
Second Chair shows the music playing in the Music app on a person's Mac as Now Playing on their iPhone: on the Lock Screen, in StandBy, in Control Centre and on Apple Watch. Its controls go back to the Mac. It is the iPhone half of a pair: Second Chair for Mac is a free, notarised download from https://madewithmerritt.com/second-chair/. There is no account or sign-in.

To review without a Mac, use the built-in demo:
1. Open Second Chair and tap Continue.
2. On Pair with Mac, tap Try a Demo. A simulated Mac called "Demo Mac" plays three invented songs. Nothing plays aloud.
3. Tap Show in Now Playing.
4. Lock the iPhone. The Lock Screen shows the demo song with its artwork; play, pause, skip and scrub work there and in Control Centre. With the iPhone locked, on its side and charging, it shows in StandBy.
5. Leave Demo, at the top of the app, goes back to pairing.

What the demo can't show:
- Continue Listening moves the song from the Mac to Apple Music on the iPhone and back. It needs the real Mac, so the demo only describes it. The attached video shows it with a real Mac.
- The optional reminder ("Remind When Music Starts") comes from the server, so it's hidden in the demo.

Permissions:
- Apple Music (media library) access is asked for only when the person uses Continue Listening, which plays the song in Apple Music on the iPhone.
- Notifications are asked for only when the person turns on the reminder. The reminder, and the alert for Continue from iPhone (asked for at the Mac), are time-sensitive, so they show during a Focus.

Background: the app's remote-notification background mode lets the Mac's "Continue from iPhone" start the hand-over while the app isn't open. Now Playing updates reach the Lock Screen through the Now Playing push type of Apple's remote media session.

Privacy: no accounts, ads, analytics or tracking. Policy: https://madewithmerritt.com/privacy/#second-chair
```

### Review video

About 90 seconds, filmed with a real Mac and iPhone, uploaded as the attachment or as an
unlisted link in the notes. Shot list:

1. Second Chair in the Mac's menu bar, then Pair iPhone… and its six-digit code.
2. The code typed on the iPhone, then Allow clicked on the Mac.
3. Music playing on the Mac; on the iPhone, Show in Now Playing.
4. The iPhone locked: the song on the Lock Screen. Pause and skip there, and the Mac follows.
5. The iPhone on its side, charging: StandBy.
6. Continue on iPhone: the Mac pauses and Apple Music on the iPhone carries on.
7. Continue on Mac: back to the Mac.

## Screenshots

**Required:** the 6.9-inch iPhone set, 1320 × 2868, portrait. App Store Connect scales it
down for smaller iPhones. No iPad set: the app is iPhone only (`TARGETED_DEVICE_FAMILY = 1`).

The four in [`screenshots/`](screenshots/), in this order:

| # | File | Shows | Caption |
| --- | --- | --- | --- |
| 1 | `1-lock-screen.jpg` | The Lock Screen playing Low Sun | Your Mac’s music, *on your Lock Screen.* |
| 2 | `2-standby.jpg` | StandBy with Low Sun, Small Hours and Ticket Hall | And in StandBy, *on the charger.* |
| 3 | `3-controls.jpg` | The app: Now Playing on Mac, controls, volume | *Press it here.* It happens there. |
| 4 | `4-continue.jpg` | The app, with Continue Listening enlarged | Take your music with you. *Then bring it back.* |

They show the demo's invented records, never real album art. They were captured on an iPhone
15 Pro on 16 November 2026, with the Debug build's screenshot mode (see the iPhone README).
Each one sits in the website's iPhone 18 Pro frame, on its record's colour, with an IvyPresto
Headline Light caption. To remake them:

1. `render_frames.py`, run against the website's `_docs/devices`, renders the frames at
   1172 px.
2. `compose.py` sets each screenshot.

Both read the website's folder and the Adobe Fonts copy of IvyPresto on this Mac; `compose.py` takes the raw device captures from a `shots/` folder beside this one, which isn't kept. The font
files aren't in the repository, and mustn't be.

Screenshot 1 shows the Lock Screen as it was: the wallpaper, and the widgets for activity,
sunset, temperature and a Melbourne clock.
