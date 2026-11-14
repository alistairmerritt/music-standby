# Background updates

Apple's documented way to update a remote session while the app isn't running is an APNs push. The push wakes the extension, which receives `update(_:)`. There is no documented way to keep a live connection open from a suspended app.

**The Mac can't reach a locked iPhone directly.** A server has to send pushes, and the APNs signing key mustn't ship inside the Mac app. The route is Mac → server → APNs → extension.

Pushes are only needed when state changes, such as track, play or pause, or a seek. The system extrapolates progress from `elapsedTime` and `timestamp`.

## What the client already does

| Token | Purpose | Observed in | Stored by |
| --- | --- | --- | --- |
| Push-to-start | Start a session while the app isn't running | `RemoteSessionController` | `MockPushTokenRegistrar` |
| Session update | Update or end one session | `MacRemoteSession` | `MockPushTokenRegistrar` |

Both appear in Diagnostics. `RelayPushTokenRegistrar` sends them to the relay once it exists, and invalidates a session's token when the session ends.

## Setup

1. Use a paid Apple Developer team.
2. Register `com.alistairmerritt.MusicStandBy` with the Push Notifications capability, and the App Group `group.com.alistairmerritt.MusicStandBy` on both App IDs. `xcodebuild -allowProvisioningUpdates` adds push by itself; the App Group has to be registered on the developer site or in Xcode.
3. Create an APNs auth key (`.p8`) and keep it on the server only.
4. `Signing/App.entitlements` sets `aps-environment` to `development`. Xcode switches this for distribution builds.

## Sending a push

```
apns-topic: com.alistairmerritt.MusicStandBy.push-type.nowplaying
apns-push-type: nowplaying
```

Send `start` to the push-to-start token, and `update` or `end` to the session token. The `id` must match the session.

```json
{
  "aps": {
    "event": "update",
    "timestamp": 1794096000,
    "attributes": {
      "id": "mac-mock",
      "macName": "Studio Mac",
      "revision": 42,
      "isPlaying": true,
      "elapsedTime": 12.5,
      "timestamp": "2026-11-08T08:00:00Z",
      "canGoNext": true,
      "canGoPrevious": true,
      "track": {
        "id": "track-1",
        "title": "Song",
        "artist": "Artist",
        "album": "Album",
        "duration": 200,
        "artworkID": "a1",
        "artworkURL": "https://example.com/a1.jpg"
      }
    }
  }
}
```

An `end` event needs only `id` in `attributes`. `artworkURL` is needed for songs whose artwork isn't already cached, since a push can't carry an image.

## On a device

Settled on an iPhone 15 Pro, iOS 27.2, on 11 November 2026 (see [STATUS.md](STATUS.md)):

- **The path.** `apsd` receives the push and hands it to `mediaremoted` ("Received push on topic …, environment: development"), which launches the extension if needed and calls its `updateSession`, with a 10 s watchdog. A change at the Mac reached the phone 1.4–3 s later.
- **The extension needs no `aps-environment`.** Only the app has it.
- **Dates.** The system's decoder could not read the relay's ISO-8601 time with milliseconds, and the error it then sent back over XPC aborted the extension. The attributes now code `timestamp` and `artworkURL` as strings themselves, so they don't depend on the decoder's settings.

Still open:

- Any push budget or rate limit. None is documented for `nowplaying`.
- How long the system waits for an HTTPS call made inside a command handler. Calls of up to 250 ms worked on a real iPhone; no limit is documented. Commands go to the relay directly from the extension; see [RELAY-CLIENT-CONTRACT.md](RELAY-CLIENT-CONTRACT.md).
- Whether `AttributesDecodingFailure` crosses XPC without the abort.

## ActivityKit fallback

Not built. It's only worth building if test 6 in [DEVICE-TESTING.md](DEVICE-TESTING.md) shows remote sessions don't appear in StandBy. A Live Activity would be a legitimate alternative, but it wouldn't be the native Now Playing interface.
