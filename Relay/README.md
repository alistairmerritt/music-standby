# Relay

The server between the Mac companion and the iPhone. It implements
**[docs/relay/API-v1.md](../docs/relay/API-v1.md)**. It is a Cloudflare Worker with one Durable Object per
pairing. It runs locally under `wrangler dev`, the same `workerd` runtime Cloudflare uses,
and is deployed to a `workers.dev` hostname, sending real APNs pushes (see
[Deployment](#deployment)).

| File | What |
| --- | --- |
| `src/index.ts` | Routing, pairing creation and claims, the APNs connectivity probe |
| `src/pairing.ts` | `Pairing` Durable Object: credentials, the Mac WebSocket, sessions, commands and acks, push tokens, artwork |
| `src/directory.ts` | `Directory` Durable Object: live pairing codes (hashed, one-time) and rate limits |
| `src/push.ts` | `PushSender`: `MockPushSender` (records pushes) and `APNsPushSender` (ES256 JWT, `nowplaying` pushes) |
| `src/crypto.ts` | Tokens, codes, hashing, constant-time comparison, artwork URL signatures |
| `src/protocol.ts` | The shared protocol's JSON shapes, mirrored from `Shared/StandByProtocol` |
| `tools/mock-phone.mjs` | A command-line iPhone: pairs, reads the session, sends commands, fetches artwork |
| `tools/e2e-local.mjs` | End-to-end test: real Mac companion ↔ local relay ↔ simulated iPhone |

## Run

```bash
npm install
```

```bash
npm test
```

```bash
npm run dev
```

`npm test` runs the suites inside `workerd` through `@cloudflare/vitest-plugin`. `npm run dev`
serves `http://127.0.0.1:8787` with local Durable Object storage.

## End-to-end on one Mac

```bash
node tools/e2e-local.mjs --msbctl ../MacCompanion/.build/swiftc/msbctl
```

```bash
node tools/e2e-local.mjs --msbctl ../MacCompanion/.build/swiftc/msbctl --playback
```

The harness starts its own relay on port 8791 and the real Mac companion (`msbctl watch
--relay`), then acts as the iPhone. It checks:
- pairing with approval on the Mac, and one-time codes and credentials;
- forged and malformed credentials;
- state delivery and session checks on commands;
- artwork through its signed URL;
- the Mac killed and restarted, the relay restarted;
- session end and unpairing.

With `--playback`, Music must already be playing. The harness then sends real next, pause,
play and a duplicated next, and leaves Music paused. It never changes the volume or launches
Music.

With `--relay URL` the same checks run against a deployed relay instead; see
[Deployment](#deployment).

To drive it by hand, run `npm run dev`, then
`msbctl watch 600 --relay http://127.0.0.1:8787 --pair`, then
`node tools/mock-phone.mjs pair <code>` (type `approve` into `msbctl`), then
`node tools/mock-phone.mjs cmd next`. Since 11 November the phone can also `cmd seek 90`,
`cmd setVolume 0.4` (Music's own volume, 0 to 1) and `cmd selectOutput <id>`, with the ids
from `playback.outputs` in `session`.

## Configuration

| Variable | Default | |
| --- | --- | --- |
| `PUSH_MODE` | `apns` | Sends real pushes with the three secrets below; without them, and with `mock`, it records them instead |
| `APNS_KEY_P8`, `APNS_KEY_ID`, `APNS_TEAM_ID` | — | Secrets (`wrangler secret put`). Never in `wrangler.toml` |
| `APNS_ENVIRONMENT` | `development` | Where a pairing's pushes go first. A token refused there with `BadDeviceToken` is tried once in the other environment, and the one that delivers is kept for the pairing (see [APNs status](#apns-status)) |
| `APNS_TOPIC` | `com.alistairmerritt.MusicStandBy.push-type.nowplaying` | |
| `APNS_APP_TOPIC` | `APNS_TOPIC` without `.push-type.nowplaying` | Topic of reminder alerts |
| `REMIND_AFTER_MS` | 1800000 | How long the Mac must not have played before a reminder |
| `ARTWORK_FOLLOW_UP_MS` | 700 | Delay before an update with new artwork is sent again |
| `DEV_ENDPOINTS` | `0` | `1` enables `/v1/dev/pushes` and `/v1/dev/apns-probe`. `npm run dev`, the tests and the harness set it. A deployment leaves it off, except for a minute to run the APNs probe |
| `PUBLIC_BASE_URL` | the origin the Mac connected to | Base of artwork URLs |
| `ACK_TIMEOUT_MS`, `DISCONNECT_GRACE_MS`, `PAUSED_TIMEOUT_MS` | 1200, 60000, 0 | `PAUSED_TIMEOUT_MS` 0 never ends a paused session |

## Deployment

Deployed on 10 November 2026 to a `workers.dev` hostname on the owner's free Cloudflare
account. The hostname is left out of this public repository; ask for it. SQLite-backed
Durable Objects are on Cloudflare's free plan.

```bash
npm run deploy
```

That deploys `wrangler.toml` as it stands: `PUSH_MODE=apns`, `DEV_ENDPOINTS=0`. Against the
deployment, the harness skips the relay restart and unpairs its test Mac when it finishes:

```bash
node tools/e2e-local.mjs --msbctl ../MacCompanion/.build/swiftc/msbctl --relay https://HOST
```

On 10 November it passed 19/19 read-only, then 29/29 with `--playback`: Next, Pause and Play
from the simulated iPhone changed the real Music.app through Cloudflare, acknowledged in
62–156 ms round trip, and the artwork came through its signed URL.

Later on 10 November the artwork wait (a GET for artwork the Mac was just asked for waits up to
3 s for the upload instead of answering `404`) was deployed as version `cb80f918`, after
`npm test` (48 tests) and the local harness with `--playback` (31/31) passed. A real iPhone
then downloaded artwork for two new tracks with no `404`.

On 11 November real pushes were turned on, as version `1eec6457`. The secrets were set with
`wrangler secret put` (`APNS_KEY_P8` from the `.p8` file, `APNS_KEY_ID`, `APNS_TEAM_ID`); the
key was first checked against APNs' sandbox, which answered `BadDeviceToken` for a dummy
device, so the provider token, team and topic were accepted. Two bugs that had never run
were fixed first, with tests (52 in all): the sender called the global `fetch` as a method,
which Workers reject with "Illegal invocation", and it signed a new provider token for every
push, which APNs refuses more than once every 20 minutes. On a real iPhone, every `update`
push got `200` and reached the phone 1.4–3 s after the change at the Mac.

Also on 11 November, sessions were made to last as long as the pairing (version `734d52e1`):
iOS shows only a session the app asked for while open, so a replacement started by push
stayed hidden. On the iPhone, with the app in the background: Music stopped, played, quit,
relaunched and played a new song, and Control Centre followed every step in the one session.

Then opt-in reminders were added (version `2d42be72`): a phone that turns them on gets "Music
playing on <Mac>" when the Mac starts playing after 30 minutes without, so a dismissed player
can be brought back with a tap. 58 tests pass. On the iPhone, with `REMIND_AFTER_MS` set to 20 s
for the test, the reminder arrived after a dismissal, and tapping it brought the player back.

Then a follow-up update for new artwork (version `ef0fa938`). iOS suspends the phone's
extension about a second after each update and doesn't wake it just to get an image, so
artwork often never showed. After an `update` push that names artwork the session hasn't
pushed before, the relay sends the same attributes again after `ARTWORK_FOLLOW_UP_MS`. That
wakes the extension again once the image is cached. It's skipped if a newer update, another
session or a new token came in meanwhile. 60 tests pass. On the iPhone, with the Mac
uploading the artwork first and the extension fetching it at once, the artwork showed.

On the evening of 11 November, seek, volume and output selection (contract branch
`contract/seek-volume`). The relay passes the three value commands
through with their `position`, `level` or `outputID`, refusing a non-numeric value with `400`,
and copies the Mac's `volume` into push attributes; `playback.outputs` reaches the phone in
`GET /v1/session` as the Mac sent it. 61 tests pass, and the local harness with `--playback`
38/38 against the real Music: seek to 30 s, volume 1 → 0.3 → 1, an unknown output refused,
the current output re-selected. Deployed early on 12 November as version `c8c0ac42`. From the
real iPhone that morning, Control Centre's scrubber moved Music 14 s → 124 s, its volume
slider showed and set Music's volume, and the app's Play To picker switched to a HomePod and
back (see `docs/ios/STATUS.md` on `feature/ios`).

Then the reminder became Time Sensitive (version `eeae1bd9`, 12 November): it carries
`interruption-level: time-sensitive` and `relevance-score: 1`, still with no sound. As an
ordinary alert, a Focus held it back, and StandBy usually runs under a Work or Sleep Focus, so
it never appeared there. 61 tests pass. Not yet seen arriving in StandBy, which needs a
30-minute break in playback.

Later on 12 November, each pairing finds its own APNs environment (see
[APNs status](#apns-status)), so TestFlight builds, whose tokens are production ones, get
their pushes from the same relay as builds from Xcode. 65 tests pass, and the local harness
21/21. **Not yet deployed.** Until it is, a TestFlight build's tokens are sent to the
sandbox, refused with `BadDeviceToken` and forgotten.

To probe APNs from the deployment, turn the dev endpoints on for a minute, then off again:

```bash
npx wrangler deploy --var DEV_ENDPOINTS:1
curl https://HOST/v1/dev/apns-probe
npx wrangler deploy
```

## Security

- **Credentials:** 256-bit random bearer tokens, stored only as SHA-256 hashes, compared in
  constant time. Mac and phone credentials are separate, and unpairing revokes both.
- **Pairing:** a code is six CSPRNG digits, valid for five minutes, used once, stored hashed,
  and grants nothing until the Mac approves.
- **Rate limits:** ten claims a minute and five pairings an hour per address. Five wrong codes
  clear every live code.
- **Logs:** tokens, codes and push tokens are never logged; ids are logged truncated.

## APNs status

- **Live since 11 November.** `APNsPushSender` sends `start`, `update` and `end` pushes, and
  reminders. The provider token is
  stored in the pairing's Durable Object and reused for 30 minutes, so an evicted object
  doesn't sign a new one; APNs' `ExpiredProviderToken` drops it.
- **Each pairing finds its own environment (12 November).** Builds from Xcode get sandbox
  tokens; TestFlight and App Store builds get production ones, and a token doesn't say which.
  Pushes go first to `APNS_ENVIRONMENT`. APNs answers `400 BadDeviceToken` to a token sent to
  the wrong environment, so that answer is tried once in the other one; if it's delivered
  there, that environment is stored with the pairing (`apnsEnvironment`) and used from then
  on. A phone that moves between a development build and TestFlight costs one extra request.
  The same provider token works in both.
- **Tokens APNs rejects are forgotten**: `410`, `DeviceTokenNotForTopic`, or `BadDeviceToken`
  from both environments. A start push to a token from an older build got
  `400 BadDeviceToken`, and the relay dropped it; the phone then registered fresh tokens.
- **Locally, `workerd` can't reach APNs**: it has no HTTP/2 client. `npm run dev` and the
  tests have no secrets, so they record pushes (`/v1/dev/pushes`) instead.

## Known limits

Deliberate for version 1, and fine for one Mac and one phone:

- **Push pacing.** There's no one-per-second cap. The Mac already sends only visible changes,
  and the relay pushes once per accepted state. `apns-collapse-id` isn't set. A skip, a pause
  and a skip gave four pushes, all delivered.
- **One provider token per pairing.** Fine for one Mac; many pairings sharing a key would
  need one token between them.
- **Artwork** lives in Durable Object storage: up to 1 MB each, the 64 most recent per
  pairing. R2 is the move if that's ever too small.
- **One phone per Mac.** Approving a new phone revokes the old phone's credential and ends
  its session.
- **Pairing claims are polled** every 2 s rather than pushed.
- **A session the phone ends** stays ended until the Mac's next listening session.
