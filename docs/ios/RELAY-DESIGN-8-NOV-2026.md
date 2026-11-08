# Relay architecture — design proposal

8 November 2026. A proposal for review by the Mac developer and the iOS developer,
not a decision. Nothing here has been built or tested.

Evidence labels, as in `AUDIT-8-NOV-2026.md`:

- **[DOCS]** — confirmed against Apple's or Cloudflare's current published documentation.
- **[SOURCE]** — read out of the code in this worktree.
- **[ASSUMPTION]** — needs a real SDK build, a device, or a deployed relay to settle.

---

## 0. Summary

The audit's B1 said the Now Playing extension has no path to the Mac. The fix is the
one Apple describes: the extension talks to a server, and the server talks to the Mac.

> "The user interacts with the iPhone system UI. The system calls a command handler in
> the app extension. The extension sends the command to the server. The server notifies
> the speaker." — WWDC26 session 312 **[DOCS]**

So the shape is not in question. What follows is the smallest relay that implements it.

**Recommended stack:** one Cloudflare Worker, one Durable Object per pairing, one R2
bucket for artwork. The Mac holds a WebSocket to the Durable Object. The extension makes
short authenticated HTTPS POSTs. The relay holds the APNs key and owns the session
lifecycle. Expected cost: **$0/month**, free tier, for one user.

**One gate before committing to it:** Cloudflare has never documented that `fetch()`
negotiates HTTP/2 outbound, and APNs accepts nothing else. Community reports say it works
in deployed Workers; `workerd` (local dev) has no HTTP/2 client at all, so it cannot be
tested locally. Spike this first (§8). The fallback is a single Node process on a $5 VPS
exposing the identical endpoints, so no client code changes either way.

---

## 1. Architecture

```
   ┌─────────────────────────────┐                   ┌──────────────────────────────┐
   │ Mac — companion app         │                   │ iPhone                       │
   │ observes Apple Music        │                   │                              │
   │ emits PlaybackMessage       │                   │  ┌────────────────────────┐  │
   │ applies RemoteCommand       │                   │  │ NowPlaying extension   │  │
   └──────────────┬──────────────┘                   │  │ MacRemoteSession       │  │
                  │                                  │  │  · command handlers    │  │
       wss, one long-lived socket                    │  │  · session push token  │  │
       ▲ state, acks, artwork refs                   │  │  · artwork fetch       │  │
       ▼ commands                                    │  └──┬──────────────┬──────┘  │
                  │                                  │     │              │         │
   ┌──────────────┴──────────────────────────┐       │     │ POST         │ GET     │
   │ RELAY                                   │       │     │ /v1/commands │ artwork │
   │  Worker  — HTTP endpoints, APNs sender  │◄──────┼─────┘◄─────────────┘         │
   │  Durable Object (1 per pairing)         │       │                              │
   │    · the Mac's WebSocket                │       │  ┌────────────────────────┐  │
   │    · sessionID + lifecycle              │       │  │ Main app               │  │
   │    · push tokens (start + session)      │◄──────┼──┤ suspended most of the  │  │
   │    · pairing codes, token hashes        │       │  │ time; registers the    │  │
   │  R2     — artwork by sha256             │       │  │ push-to-start token    │  │
   │  Secret — APNs .p8, team id, key id     │       │  └────────────────────────┘  │
   └──────────────┬──────────────────────────┘       └──────────────▲───────────────┘
                  │ HTTPS/2                                         │
                  ▼                                                 │
            ┌──────────┐   start / update / end                     │
            │   APNs   │  apns-push-type: nowplaying ───────────────┘
            └──────────┘
```

Three properties worth stating, because they are what make this small:

1. **The relay is the only thing holding the APNs key.** Neither app ever sees it.
2. **The relay owns the session identifier and the session lifecycle.** Neither app has
   to reason about when a Now Playing session starts or ends.
3. **The relay translates.** The Mac speaks `PlaybackMessage`; the phone receives
   `MacPlaybackAttributes`. The relay does that mapping, so neither side's protocol has
   to change to accommodate the other. **[SOURCE]** The two types already line up field
   for field (`TemporaryProtocol.swift`, `MacPlaybackAttributes.swift`).

---

## 2. Flow A — Mac to phone (state)

1. Apple Music changes on the Mac. The companion app emits a `PlaybackMessage` with an
   incremented `revision` and `capturedAt` set to now.
2. The Mac sends it over the open WebSocket: `{"type":"state","message":{…}}`.
3. The Durable Object decides whether this is a **start**, an **update** or nothing:
   - no active session and `isPlaying == true` → mint a fresh `sessionID` (UUID v4),
     send `start` to the push-to-start token;
   - active session → send `update` to that session's push token;
   - no meaningful change → drop it (see coalescing below).
4. If the message names an `artworkID` the relay has no bytes for, it asks the Mac for
   them (`{"type":"artwork-request","artworkID":"…"}`), stores them in R2 under their
   SHA-256, and sets `artworkURL` to the relay's own URL for that hash.
5. The relay builds `MacPlaybackAttributes` and POSTs the push to APNs.
6. The system wakes the extension and calls `session(_:)` (start) or `update(_:)`
   (update). **[DOCS]**

**Coalescing.** Push only on a change the user can see: track id, `isPlaying`,
`canGoNext`/`canGoPrevious`, or an `elapsedTime` that differs from the extrapolated
position by more than 2 s. Never push for ordinary progress — `MacPlaybackAttributes.elapsed(at:)`
already extrapolates from `timestamp`. **[SOURCE]** Cap at one push per second per
session, coalescing anything that arrives inside the window and sending the latest.

**Mapping.** `PlaybackMessage` → `MacPlaybackAttributes`, done in the relay:

| Source (`PlaybackMessage`) | Target (`MacPlaybackAttributes`) |
| --- | --- |
| — | `id` = the relay's `sessionID` |
| — | `macName` = from the pairing record |
| `revision` | `revision` |
| `isPlaying` | `isPlaying` |
| `elapsedTime` | `elapsedTime` |
| `capturedAt` | `timestamp` |
| `track` (`TrackMetadata`) | `track` (`SessionTrack`) + `artworkURL` |
| `canGoNext` / `canGoPrevious` | same |

**`id` must be a fresh UUID per session.** Apple's sample calls it "the server's
sessionID, which must be unique" **[DOCS]**. The current mock uses the constant
`"mac-mock"` **[SOURCE]**; reusing one id across start/end cycles is the kind of thing
that works in testing and fails after the first `end`.

---

## 3. Flow B — phone to Mac (commands)

1. The user taps Pause on the Lock Screen. The system calls the `MediaCommand` closure
   inside the extension. The closure is `() async throws -> Void`. **[DOCS]**
2. The extension POSTs `/v1/commands` with the existing `RemoteCommand` body, a bearer
   token from the shared Keychain, and `Idempotency-Key: <command.id>`.
3. The Worker routes to the pairing's Durable Object, which wakes from hibernation and
   writes `{"type":"command","command":{…}}` to the Mac's WebSocket.
4. The Mac applies it, then sends back `{"type":"ack","ack":<CommandAck>}` and, normally
   in the same breath, a new `{"type":"state",…}`.
5. The Durable Object holds the HTTP response open until the ack arrives or **1.2 s**
   elapses, then answers the extension with the `CommandAck` or `504 mac_unreachable`.
   The extension uses a **1.5 s** client timeout, so it can never outlast the relay.
6. The state change reaches the Lock Screen the normal way, through flow A. The ack is
   only there so the extension can `throw` when the command did not land.

**Why hold the response rather than return 202.** The command closure is `async throws`
and the system is already awaiting it. Throwing is the only signal available that a
command failed, and the audit's B2 showed how bad silent no-ops look — two controls that
appear to work and two that appear dead. Holding for ~1 s buys real feedback at no
architectural cost.

**Why not optimistic local mutation.** Keep `MacPlaybackAttributes` authoritative from
the Mac. The round trip is a LAN-to-edge hop; it will normally be well under 300 ms, and
an optimistic flip that later disagrees with the Mac is worse than a short wait. This
also deletes the `MockLibrary` guess-the-next-track model that caused B2. **[SOURCE]**

---

## 4. Endpoints and payloads

Base: `https://relay.<domain>` — a `*.workers.dev` hostname is fine to start.

All bodies are JSON. All authenticated calls carry `Authorization: Bearer <token>`.
Every response carries `X-Protocol-Version: 1`.

### Mac ↔ relay — WebSocket

```
GET wss://relay.<domain>/v1/mac/socket
Authorization: Bearer <macToken>
```

Frames, Mac → relay:

```json
{"type":"hello","macName":"Studio Mac","protocolVersion":1}
{"type":"state","message":{"revision":42,"isPlaying":true,"elapsedTime":12.5,
  "capturedAt":"2026-11-08T08:00:00Z","canGoNext":true,"canGoPrevious":true,
  "track":{"id":"track-1","title":"Song","artist":"Artist","album":"Album",
           "duration":200,"artworkID":"a1"}}}
{"type":"ack","ack":{"commandID":"…","accepted":true,"revision":43}}
{"type":"artwork","artworkID":"a1","sha256":"…"}
```

Frames, relay → Mac:

```json
{"type":"command","command":{"id":"5C1F…","kind":"pause"}}
{"type":"artwork-request","artworkID":"a1"}
{"type":"paired","phoneName":"Alistair's iPhone"}
{"type":"revoked","reason":"unpaired"}
```

`message`, `ack` and `command` are the existing `PlaybackMessage`, `CommandAck` and
`RemoteCommand` types, encoded as they stand. **[SOURCE]** The envelope is new; the
protocol inside it is untouched.

### Pairing

```
POST /v1/pair/begin                         (Mac, no auth, rate-limited)
  → 200 {"pairingID":"…","code":"472915","expiresAt":"2026-11-08T08:05:00Z",
         "provisionalToken":"…"}

POST /v1/pair/claim                         (phone app, no auth, rate-limited)
  { "code":"472915", "deviceName":"Alistair's iPhone" }
  → 200 {"pairingID":"…","phoneToken":"…","mac":{"id":"…","name":"Studio Mac"}}
  → 404 {"error":"unknown_or_expired_code"}
  → 429 {"error":"too_many_attempts","retryAfter":60}
```

`mac` is the existing `PairedMac`. **[SOURCE]** The Mac learns the pairing succeeded over
its socket (`{"type":"paired",…}`) and exchanges its `provisionalToken` for a permanent
`macToken` on the next connect.

### Tokens

```
POST /v1/tokens/start                       (phone app, bearer phoneToken)
  { "pushToStartToken":"<hex>" }            → 204

POST /v1/tokens/session                     (extension, bearer phoneToken)
  { "sessionID":"…", "pushToken":"<hex>" }  → 204
```

These two replace `PushTokenRegistrar`, which the audit already named as the one client
seam a backend has to fill. **[SOURCE]** Add `invalidate(sessionID:)` to that protocol
(audit D2) and map it to `DELETE /v1/tokens/session/{sessionID}`.

### Commands

```
POST /v1/commands                           (extension, bearer phoneToken)
Idempotency-Key: 5C1F…
  { "command": {"id":"5C1F…","kind":"pause"} }
  → 200 {"ack":{"commandID":"5C1F…","accepted":true,"revision":43}}
  → 504 {"error":"mac_unreachable"}
  → 401 {"error":"pairing_revoked"}
```

### Artwork

```
PUT /v1/artwork/{sha256}                    (Mac, bearer macToken, image/jpeg)
  → 201 {"url":"https://relay.<domain>/v1/artwork/<sha256>"}

GET /v1/artwork/{sha256}                    (extension, bearer phoneToken)
  → 200 image/jpeg, Cache-Control: immutable
```

Serving artwork from the relay is what closes the audit's C1. The extension's fetch is no
longer to an arbitrary URL from a push payload; it is to one known host, so the hardening
collapses to a host check plus the size and content-type caps in audit D4. **[SOURCE]**

### Housekeeping

```
GET    /v1/session                          (phone app, bearer) → current session or null
POST   /v1/session/end                      (phone app, bearer) → 204
DELETE /v1/pairing                          (phone app, bearer) → 204, revokes both tokens
```

---

## 5. Pairing and authentication

**No accounts, no passwords, no identity provider.** A pairing is a row; the tokens are
bearer capabilities for that row.

1. The Mac calls `/v1/pair/begin`. The relay generates a six-digit code from a CSPRNG,
   stores `sha256(code)` against a fresh `pairingID`, sets a **5-minute** expiry, and
   returns the code for display.
2. The user types it on the phone. `/v1/pair/claim` looks up the hash, and on a match
   mints two 256-bit random tokens, stores only their SHA-256 hashes, and returns the
   phone's.
3. The code is destroyed on first successful claim and on expiry.

**Brute force.** 10^6 codes, one live at a time, 5-minute window. The relay allows **5
attempts per code** and **10 claim attempts per IP per minute**, then 429s. That caps an
attacker at ~50 guesses against a live code — about 1 in 20,000 even before the per-code
limit bites. Good enough without an account; the audit's C5 flagged the current
unlimited-attempt mock. **[SOURCE]**

**Where the phone token lives.** The extension needs it while the device is locked, so:

- Keychain, `kSecAttrAccessible = kSecAttrAccessibleAfterFirstUnlock`, in a shared access
  group. **Not** `WhenUnlocked` — a docked, locked phone would be unable to read it.
- This needs a `keychain-access-groups` entitlement on both targets
  (`$(AppIdentifierPrefix)com.alistairmerritt.MusicStandBy`). Neither entitlements file
  has one today. **[SOURCE]**
- Fallback if keychain sharing proves awkward: the App Group container file, written with
  `.completeUntilFirstUserAuthentication` set explicitly. Workable, weaker, and the audit
  already noted the current token file sets no protection class at all (C2). **[SOURCE]**

**Expiry and rotation.** The phone token does not expire on a timer. This is deliberate:
a refresh round trip inside a Lock Screen command handler is a second network hop at the
worst possible moment. Instead:

- Tokens carry a generation number. `DELETE /v1/pairing`, a re-pair, or an explicit
  revoke bumps it and invalidates the old token immediately.
- A `401 pairing_revoked` is the signal. The extension surfaces it by throwing; the app,
  next time it runs, sees the same 401 and shows "Pair again".
- If rotation is wanted later, the relay can return `X-Rotate-Token` on any authenticated
  response; the **app** adopts it on next launch. The extension never rotates.

---

## 6. APNs requirements

All confirmed against *Publishing remote media sessions* unless marked otherwise.

| Item | Value |
| --- | --- |
| Push type | `apns-push-type: nowplaying` **[DOCS]** |
| Topic | `apns-topic: com.alistairmerritt.MusicStandBy.push-type.nowplaying` **[DOCS]** |
| Host | `api.sandbox.push.apple.com` (dev) / `api.push.apple.com` (prod), port 443 or 2197 **[DOCS]** |
| Auth | JWT, ES256, `kid` = Key ID, `iss` = Team ID, `iat` = now **[DOCS]** |
| JWT reuse | Refresh no more than once every 20 minutes, no less than once every 60 **[DOCS]** |
| Events | `start` → push-to-start token; `update`, `end` → session token **[DOCS]** |
| `end` payload | `attributes` needs only `id` **[DOCS]** |

Worth knowing: **`nowplaying` does not appear in Apple's `apns-push-type` table** in
*Sending notification requests to APNs*, which lists twelve values and not this one.
**[DOCS]** The NowPlaying article is the only place it is specified. Treat the article as
authoritative and expect tooling that validates against the older table to reject it.

Recommended headers beyond the required two:

- `apns-priority: 10` for state changes. **[ASSUMPTION]** — priority semantics are
  documented generally but not for this push type.
- `apns-expiration: <now + 30>`. A state update delivered two minutes late is worse than
  not delivered; `0` would mean a single attempt with no retry at all.
- `apns-collapse-id: <sessionID>`. Queued updates for one session should collapse to the
  newest. **[ASSUMPTION]** for `nowplaying` specifically.

**Token handling.** Store both tokens with a `receivedAt`, last write wins. On `410
Unregistered` or `400 BadDeviceToken`, delete that token immediately and stop pushing to
it; if it was a session token, mark the session ended. This is the audit's C2 — Apple's
instruction is to "invalidate the outdated token promptly so it cannot be reused".
**[DOCS]**

**Ordering problem to design around.** After `start`, the relay has no session push token
until the extension registers one via `/v1/tokens/session`. Until then it cannot send
`update`. Hold the latest state, send it as soon as the token lands, and if nothing
arrives within ~10 s, re-send `start` with the same `id`. Whether a repeated `start` with
an existing `id` is idempotent is **[ASSUMPTION]** — Apple does not say.

---

## 7. Failure handling and session lifecycle

**The relay owns the lifecycle.** This is the single most useful thing it does, because
the audit's B3 was that nothing ever ends a session, so the Lock Screen keeps showing a
dead Mac.

| Event | Relay action |
| --- | --- |
| Mac WebSocket closes | Start a 60 s grace timer |
| Grace expires with no reconnect | Send `end` to the session token, clear `sessionID` |
| Mac sends `isPlaying:false` | Keep the session — a paused session is legitimate |
| Paused with no activity for 15 min | Send `end` |
| Mac sends an explicit stop | Send `end` |
| `/v1/session/end` from the app | Send `end` |
| `DELETE /v1/pairing` | Send `end`, revoke both tokens, drop the R2 prefix |
| APNs 410 on the session token | Clear `sessionID`, drop the token |

**Mac reconnection.** Exponential backoff 1 s → 30 s with jitter. Heartbeat every 30 s;
use the Durable Object's `setWebSocketAutoResponse()` for pings, which adds no wall-clock
time and is not billed. **[DOCS]** On reconnect the Mac sends `hello` and its current
state; the relay decides start-versus-update from its own record, not the Mac's.

**Command failure.** `504 mac_unreachable` → the extension throws. The system is told the
command failed, which is the honest outcome. No retry inside the handler: a second
attempt would double the time the system is waiting on a closure with no documented
budget.

**Idempotency.** `RemoteCommand.id` is already a UUID. **[SOURCE]** The relay keeps the
last ~20 command ids per pairing and replays the stored ack for a repeat rather than
sending the command twice.

**App-side reconciliation.** When the app is foregrounded it calls `GET /v1/session`. If
the relay says there is no session and the phone still has one, the app ends it locally.
This also covers the audit's B4: `requestToBecomeSystemPrimary()` has no effect from the
background **[DOCS]**, so foregrounding is the only moment the primary slot can be
re-claimed, and the app should take it whenever a session exists.

**What is deliberately not handled.** No offline command queue. If the Mac is unreachable
the command is lost and the user is told. Queuing a pause for a Mac that comes back in an
hour is worse than dropping it.

---

## 8. Cloudflare Workers and Durable Objects, or a conventional server

**Recommendation: Workers + one Durable Object + R2, gated on a spike.**

Why it fits:

- A Durable Object is a single addressable, single-threaded object with storage — exactly
  one per pairing, holding the Mac's socket and the session state, with no coordination
  problem to solve.
- WebSocket Hibernation means the idle socket costs nothing: hibernating objects incur no
  duration charge, incoming messages bill at 20:1, outgoing messages and protocol pings
  are free. **[DOCS]**
- Durable Objects are on the free plan with the SQLite backend. **[DOCS]**
- No machine, no TLS certificates, no patching, and a stable hostname out of the box.
- WebCrypto does ECDSA P-256, so the ES256 JWT is a few lines with no dependencies.

The one real risk, and it is not small:

**Cloudflare has never documented that `fetch()` speaks HTTP/2 to an origin, and APNs
speaks nothing else.** Community reports say deployed Workers do reach
`api.push.apple.com` successfully, and Workers-specific APNs libraries exist. But
`workerd`, the local runtime, has no HTTP/2 client, so this cannot be tested locally — the
first deployed push is the real test. There is no Cloudflare guarantee to rely on.

**Spike it first, before any other work.** Half an hour: deploy a Worker that signs an
ES256 JWT and POSTs any payload to `api.sandbox.push.apple.com`. A `400 BadDeviceToken`
is a pass — it means HTTP/2 was negotiated and APNs parsed the request. A connection
error is a fail.

**If it fails,** the fallback is a single Node or Bun process using `node:http2` on a $5
VPS, or on the Mac itself behind a free Cloudflare Tunnel. It exposes the identical
endpoints and frames, so nothing in either app changes. Trade-off: a mature HTTP/2 client
and a debugger you can attach, against a machine you now have to keep patched and alive.
The persistent WebSocket is marginally easier there; everything else is harder.

**Treat §4 as the contract and the platform as replaceable.** That is the point of
writing the endpoints down before writing the relay.

---

## 9. Cost

One Mac, one iPhone, a heavy listening day — 300 track changes, 100 commands, 20 new
albums.

| Item | Daily volume | Free allowance | Share used |
| --- | --- | --- | --- |
| Worker requests | ~450 | 100,000/day | 0.5% |
| Durable Object requests | ~450 (WS messages bill 20:1) | 100,000/day | <0.5% |
| Durable Object duration | near zero, hibernating | 13,000 GB-s/day | ~0% |
| R2 storage | ~2 MB/day, ~700 MB/year | 10 GB | ~7%/year |
| R2 Class A writes | ~20 | 1,000,000/month | ~0.06% |

**Expected: $0/month.** A `*.workers.dev` hostname is free; a custom domain is about
$10/year if wanted.

Workers Paid is **$5/month** and buys 10 M requests, removal of the 100,000/day cap, and
400,000 GB-s of Durable Object duration. **[DOCS]** For one user it buys nothing but the
absence of a daily cliff. Worth taking once this is something Alistair relies on daily,
not before.

An always-on alternative — a $5/month VPS, or a Mac-hosted process behind a free
Cloudflare Tunnel — costs $0–5/month plus the time to maintain it.

---

## 10. Implementation sequence

Each step is gated on the one before it. The order matters: the two steps most likely to
invalidate the design are first.

**Step 0 — the two spikes, before anything else.** Half a day.
  1. **Relay:** the APNs-from-Workers spike in §8. If it fails, switch to the conventional
     server before writing anything else.
  2. **iOS:** the audit's section E, steps 1–9. Confirm the NowPlaying framework is in the
     SDK and that the extension compiles against it. If `MacRemoteSession` cannot satisfy
     `RemoteMediaSessionRepresentable` without declaring `pushToken`, the push-token
     design changes and this document needs revising. **[ASSUMPTION]**

**Step 1 — relay skeleton.** Pairing, tokens, the Durable Object, the Mac WebSocket, and
`/v1/commands` returning a canned ack. No APNs yet. Deployable and testable with `curl`
and `websocat`.

**Step 2 — Mac developer, in parallel with step 1.** Replace the Mac's transport with the
WebSocket client: `hello`, `state`, `ack`, artwork upload, reconnect with backoff.
`PlaybackMessage`, `RemoteCommand` and `CommandAck` are unchanged — only the envelope and
the destination are new.

**Step 3 — iOS developer, in parallel with step 1.** Three changes, all already named in
the audit:
  - `PushTokenRegistrar` → the real HTTPS implementation, plus `invalidate(sessionID:)`.
  - A `CommandSender` protocol beside it, called from `MacRemoteSession.handle(_:)`, so
    the command closures `try await` a real POST (audit D1). Delete `MockLibrary`'s
    optimistic guessing (audit B2).
  - The shared Keychain item and the `keychain-access-groups` entitlement.
  The App Group file and Darwin notification stay as a fast lane for when the app happens
  to be running. They are no longer the primary path.

**Step 4 — APNs in the relay.** `start`/`update`/`end`, the `PlaybackMessage` →
`MacPlaybackAttributes` mapping, coalescing, token invalidation on 410. This is the first
point at which the Lock Screen can show anything.

**Step 5 — first device test.** The audit's section E, steps 11–16, now end to end.
Specifically: does a remote session appear in StandBy at all, and does tapping Next on the
Lock Screen change the Mac.

**Step 6 — lifecycle and hardening.** The §7 table, the artwork caps from audit D4, the
restartable transport loop from audit D3, and the activation recovery from audit D5.

Steps 2 and 3 touch disjoint files in different repositories and can run at the same time.
Everything else is serial.

---

## 11. Assumptions to verify on a physical iPhone

Nothing below is settled. Each one would change part of this design.

1. **A remote session appears in landscape StandBy.** The whole premise. Apple's material
   mentions StandBy only in passing and never in the remote-session section.
2. **The extension may make outbound HTTPS inside a command handler, and the system waits
   for it.** Apple's own samples do exactly this — `try await self.client.send(.play)` —
   and instruct observing `pushTokenUpdates` from inside the extension and sending the
   token to a server. **[DOCS]** So it is the documented design. What is *not* documented
   is any budget: how long the system waits before treating the closure as hung, and
   whether a slow handler is penalised. The 1.5 s timeout in §3 is a guess made to stay
   well inside any plausible limit.
3. **The extension does not need its own `aps-environment` entitlement.** Apple documents
   no extension entitlements, and the system — not the extension — receives the push.
   The extension's entitlements file has none today. **[SOURCE]**
4. **Dates decode as ISO-8601.** Apple's sample payloads use ISO-8601 strings inside
   `attributes` and a numeric epoch for `aps.timestamp`. **[DOCS]** Whether the system's
   decoder agrees with `MacPlaybackAttributes`'s default `Codable` date strategy is
   untested. Send one of each and see which produces a correct elapsed time.
5. **A repeated `start` with an existing `id` is idempotent** (§6, the ordering problem).
6. **There is no rate limit or budget on `nowplaying` pushes.** None is documented, which
   is not the same as none existing. Live Activities have one.
7. **`apns-collapse-id` and `apns-priority: 10` behave sensibly for this push type.**
8. **A session survives the app being force-quit**, and commands still reach the
   extension afterwards. If not, the docked-phone case needs rethinking.
9. **Cloudflare Workers reach APNs over HTTP/2** (§8). Verifiable without a phone.

---

## 12. Sources

- [NowPlaying framework](https://developer.apple.com/documentation/nowplaying)
- [Publishing remote media sessions](https://developer.apple.com/documentation/nowplaying/publishing-remote-media-sessions)
- [RemoteMediaSessionRepresentable](https://developer.apple.com/documentation/nowplaying/remotemediasessionrepresentable)
- [RemoteMediaSession](https://developer.apple.com/documentation/nowplaying/remotemediasession)
- [MediaCommand](https://developer.apple.com/documentation/nowplaying/mediacommand)
- [Meet the Now Playing framework — WWDC26 session 312](https://developer.apple.com/videos/play/wwdc2026/312/)
- [Sending notification requests to APNs](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns)
- [Establishing a token-based connection to APNs](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns)
- [Durable Objects pricing](https://developers.cloudflare.com/durable-objects/platform/pricing/)
- [Workers pricing](https://developers.cloudflare.com/workers/platform/pricing/)
- [workerd issue 4841 — APNs HTTP/2 via fetch()](https://github.com/cloudflare/workerd/issues/4841)
- [cloudflare-apns2](https://github.com/themintchoco/cloudflare-apns2)
