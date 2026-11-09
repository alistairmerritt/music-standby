# Relay

The server between the Mac companion and the iPhone. It implements
**[docs/relay/API-v1.md](../docs/relay/API-v1.md)**. It is a Cloudflare Worker with one Durable Object per
pairing. It runs locally under `wrangler dev`, the same `workerd` runtime Cloudflare uses,
and is deployed to a `workers.dev` hostname with pushes still mocked (see
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
`node tools/mock-phone.mjs cmd next`.

## Configuration

| Variable | Default | |
| --- | --- | --- |
| `PUSH_MODE` | `mock` | `apns` sends real pushes; needs the three secrets below |
| `APNS_KEY_P8`, `APNS_KEY_ID`, `APNS_TEAM_ID` | — | Secrets (`wrangler secret put`). Never in `wrangler.toml` |
| `APNS_ENVIRONMENT` | `development` | `production` uses `api.push.apple.com` |
| `APNS_TOPIC` | `com.alistairmerritt.MusicStandBy.push-type.nowplaying` | |
| `DEV_ENDPOINTS` | `0` | `1` enables `/v1/dev/pushes` and `/v1/dev/apns-probe`. `npm run dev`, the tests and the harness set it. A deployment leaves it off, except for a minute to run the APNs probe |
| `PUBLIC_BASE_URL` | the origin the Mac connected to | Base of artwork URLs |
| `ACK_TIMEOUT_MS`, `DISCONNECT_GRACE_MS`, `PAUSED_TIMEOUT_MS` | 1200, 60000, 900000 | |

## Deployment

Deployed on 10 November 2026 to a `workers.dev` hostname on the owner's free Cloudflare
account. The hostname is left out of this public repository; ask for it. SQLite-backed
Durable Objects are on Cloudflare's free plan.

```bash
npm run deploy
```

That deploys `wrangler.toml` as it stands: `PUSH_MODE=mock`, `DEV_ENDPOINTS=0`. Against the
deployment, the harness skips the relay restart and unpairs its test Mac when it finishes:

```bash
node tools/e2e-local.mjs --msbctl ../MacCompanion/.build/swiftc/msbctl --relay https://HOST
```

On 10 November it passed 19/19 read-only, then 29/29 with `--playback`: Next, Pause and Play
from the simulated iPhone changed the real Music.app through Cloudflare, acknowledged in
62–156 ms round trip, and the artwork came through its signed URL.

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

- **Mocked by default.** `/v1/dev/pushes` shows what would have been sent. The `start`,
  `update` and `end` payloads, headers and ES256 provider token are unit-tested against
  Apple's documented format, including verifying the JWT signature, but have never reached
  APNs.
- **Locally, `workerd` can't reach APNs.** `GET /v1/dev/apns-probe` gets "Network connection
  lost". `curl --http2` from the same Mac gets APNs' `403 InvalidProviderToken`; `curl
  --http1.1` fails just as `workerd` does. That fits `workerd` having no HTTP/2 client.
- **A deployed Worker does reach APNs.** On 10 November the probe from the deployment got
  APNs' own `403 InvalidProviderToken`, with an `apns-id`, three times out of three: 687 ms
  cold, then about 170 ms. APNs answers only over HTTP/2, so the Worker can send pushes
  itself, with no separate push service. Real pushes still need an APNs key from the paid
  Apple Developer Program.

## Known limits

Deliberate for version 1, and fine for one Mac and one phone:

- **Push pacing.** There's no one-per-second cap. The Mac already sends only visible changes,
  and the relay pushes once per accepted state. `apns-collapse-id` isn't set. Revisit after
  real APNs testing.
- **Artwork** lives in Durable Object storage: up to 1 MB each, the 64 most recent per
  pairing. R2 is the move if that's ever too small.
- **One phone per Mac.** Approving a new phone revokes the old phone's credential and ends
  its session.
- **Pairing claims are polled** every 2 s rather than pushed.
- **A session the phone ends** stays ended until the Mac's next listening session.
