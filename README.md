# Second Chair

A companion for Apple Music on a Mac and an iPhone. Music playing on the Mac appears in the
iPhone's own Now Playing: on the Lock Screen, in StandBy, in Control Centre and on Apple
Watch. Its controls work the Mac while the sound stays on the Mac. The music can also move
between the two, from the same point in the song.

Formerly **Music StandBy**: bundle identifiers, the relay's hostname and this repository keep
the old name.

## What it does

- **Now Playing on the iPhone** for Music on the Mac: song, artwork, progress, play, pause,
  skip, seek, and Music's own volume (never the Mac's system volume).
- **Continue on iPhone:** the Mac's song carries on in Apple Music on the phone, with the
  Mac's Up Next after it, and the Mac pauses. When the Mac has little queued, as on a
  station, a station made from the song follows. Run again with nothing new on the Mac (say
  from a CarPlay automation), it carries on with the phone's own music instead.
- **Continue on Mac:** the phone's song carries on in Music on the Mac. A song the Mac's queue
  doesn't have goes as its station.
- **Continue from iPhone:** the same from the Mac's side, as a menu button or a Shortcuts
  action. The phone is woken in the background, or shown a notification with a Continue on
  Mac button, which Apple Watch shows too.
- **Shortcuts actions** on the iPhone for every control and both directions; a reminder
  notification when the Mac starts playing; Launch at Login on the Mac.

## How it works

```
Music.app ──Apple Events, remote protocol──▶ Mac companion ──WebSocket──▶ Relay ──APNs──▶ iPhone
          ◀──────────── commands ──────────── (menu bar)   ◀── commands ── (Cloudflare) ◀── HTTPS ──
```

- The **Mac companion** reads Music with raw Apple Events, plus Music's own remote-control
  protocol for Up Next and Apple Music IDs, and runs the phone's commands.
- The **relay** is a Cloudflare Worker with one Durable Object per pairing. It holds the
  latest state and artwork, passes commands to the Mac, and updates the phone's Now Playing
  through Apple's push service.
- The **iPhone app** publishes a remote media session, which iOS shows as Now Playing, and
  its extension sends the controls to the relay. Continue on iPhone uses Apple Music on the
  phone.

## In this repository

| Path | What | Read first |
| --- | --- | --- |
| [`MacCompanion/`](MacCompanion/) | The menu-bar app, its engine and `msbctl`, a command-line driver | [README](MacCompanion/README.md), [STATUS](MacCompanion/STATUS.md) |
| [`iPhoneCompanion/`](iPhoneCompanion/) | The iPhone app, its Now Playing extension and `StandByKit` | [README](iPhoneCompanion/README.md), [STATUS](docs/ios/STATUS.md) |
| [`Relay/`](Relay/) | The Cloudflare Worker | [README](Relay/README.md) |
| [`Shared/StandByProtocol/`](Shared/StandByProtocol/) | The wire protocol all three share, with an example of every message | [README](Shared/StandByProtocol/README.md), [PROTOCOL](Shared/StandByProtocol/PROTOCOL.md) |
| [`docs/`](docs/) | The relay API, iOS device notes, and an [archive](docs/archive/) of early plans | [API-v1](docs/relay/API-v1.md) |

## Status

A test release, used daily by its developer and not yet on the App Store.

- **iPhone:** iOS 27. Distributed through TestFlight.
- **Mac:** macOS 14 or later; developed on macOS 27. Notarised builds are published as GitHub
  pre-releases, though the newest features are in the source first.
- **Relay:** deployed on Cloudflare's `workers.dev`.

The status files record what has been verified on real devices and how, and what hasn't.

## Building

Each part builds on its own: see its README. Two values stay outside the repository, in
`~/.config/second-chair/`, and are passed in at build time:

- `relay-host`: the relay's hostname, built into both apps.
- `team-id`: the Apple Developer team that signs them.

Running your own copy needs an Apple Developer Program membership (push notifications,
the MusicKit app service and an APNs key) and a Cloudflare account for the relay.

## Privacy

There are no accounts. The relay keeps, per pairing: the Mac's latest playback state (song,
artist, album, Apple Music IDs, Up Next), recent artwork, push tokens and hashed credentials.
It never receives audio. Song details never go in push payloads, and logs never contain
tokens or pairing codes. The Mac looks up missing Apple Music IDs and artwork with Apple's
public iTunes Search API, sending only the album and lead artist. See
[Relay/README.md](Relay/README.md#security).

## Licence

Not yet chosen.
