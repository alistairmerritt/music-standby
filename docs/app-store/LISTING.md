# App Store listing: Second Chair for iPhone

Everything to fill in on App Store Connect for version 1.0, in the order its pages ask for it.
Written 16 November 2026, against the app's code and madewithmerritt.com/second-chair/. The
first build for review is TestFlight 202611161444, version 1.0.

**Updated 23 November 2026:** the subtitle, description and review notes are now the
final wording from the app's owner. See "Checks before submitting" under App Review
Information for what to settle first.

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
| Subtitle (30) | Apple Music, across devices *(27; see check 1 below. The earlier choice was "Your Mac's music on iPhone")* |
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

Plain text: App Store descriptions don't support bold, so the headings are plain lines.

```
Music on your Mac. Now Playing on your iPhone.

Second Chair brings music playing on your Mac to your iPhone's native Now Playing, including the Lock Screen, Control Centre, StandBy and Apple Watch.

Play, pause, skip and control your Mac's music without being at your desk. When the song changes on your Mac, your iPhone follows, even when you're away from home.

Take your music with you. Then bring it back.

Continue Listening lets you move playback between your Mac and iPhone, picking up where you left off.

Your playlists, albums, stations and playback settings can come along too, with some differences depending on how you're listening.

Make it your own.

Use Apple Shortcuts to bring your music between devices as part of your routine. Continue listening on your iPhone when you connect to CarPlay, or return to your Mac when you reconnect your headphones.

What you'll need

Second Chair works with Apple's Music app on your Mac. You'll need the free Second Chair Mac companion, available from madewithmerritt.com/second-chair.

Both devices need an internet connection. Continue Listening also requires an Apple Music subscription on your iPhone.

Designed for iOS 27 and macOS 27, with an Apple silicon Mac.

Second Chair is an independent project and isn't affiliated with Apple.
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
Second Chair is a paid iPhone companion application for Apple's Music app on macOS. The Mac companion is provided free of charge.
Mac companion: https://madewithmerritt.com/second-chair/
Setup instructions: https://madewithmerritt.com/second-chair/getting-started/
Second Chair has no user accounts or sign-in. It requires a compatible Mac running the free companion application for live remote playback.
To test the full experience:

1. Install and open Second Chair on an Apple silicon Mac running macOS 27.
2. Allow it to control Music when prompted.
3. Open Second Chair on the iPhone.
4. In the Mac menu bar, choose Pair iPhone…
5. Enter the six-digit code on the iPhone and approve the pairing request on the Mac.
6. Start playing music in the Mac's Music app.
7. Verify that the track appears in the iPhone's native Now Playing interface and that playback controls operate Music on the Mac.

Continue Listening: This feature moves actual playback between devices. It requires an Apple Music subscription on the iPhone and a separate connection to Music on the Mac.
In the Mac app, choose Connect to Music… and enter the displayed four-digit code in the Music app's Devices sidebar. Then use Continue on iPhone or Continue on Mac to transfer playback.
Without a Mac: The iPhone app includes Try a Demo, which allows reviewers to explore the interface without pairing a computer. The demo is illustrative and does not replace a live hardware test.
External services: Second Chair uses a developer-operated relay and Apple's push notification service to communicate playback information and controls between the two devices. Apple Music services are used for playback and catalogue information.
Tested hardware: MacBook Pro (2021 and 2025), MacBook Air (2025), and iPhone 13, 15 and 16.
Please refer to the supplied demonstration video for the complete pairing and playback experience.
```

### Checks before submitting (23 November 2026)

Checked against the code on `feature/widgets` and `feature/mac-menu-redesign`.

1. **The subtitle uses "Apple Music".** Guideline 5.2.5 limits Apple trademarks in metadata,
   and the subtitle is the riskiest place for one. If it's rejected: "Your Mac’s music, on
   iPhone" (27).
2. **"Try a Demo" is now "Explore the Demo"** in the redesigned first run (PR #27). Match the
   build that's submitted.
3. **Pairing:** the reviewer clicks ♪ in the menu bar first, then **Pair iPhone…**. **Connect
   to Music…** is exact; the app says "In Music, choose Second Chair under Devices and type the
   four-digit code."
4. **The notes refer to a demonstration video**, so it must be attached (shot list below).
5. **The permissions paragraph from the earlier notes is gone:** Apple Music access only for
   Continue Listening, notifications only for the reminder, the remote-notification background
   mode, and the Add to Library setting (off by default). Worth adding back briefly.
6. **"Designed for macOS 27":** the Mac app runs on macOS 14 or later (Apple silicon only);
   fine as what it's tested on.
7. Not checked: Apple Watch, and the tested-hardware list.

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
