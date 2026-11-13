# Relay API — version 1

The contract between the relay, the Mac companion and the iPhone app (app and Now Playing
extension). It builds on the shared protocol in `Shared/StandByProtocol`
([PROTOCOL.md](../../Shared/StandByProtocol/PROTOCOL.md)): every body and frame below is a
Swift type there, with a JSON example in `Shared/StandByProtocol/Examples/` that the tests
decode and re-encode. It turns `docs/ios/RELAY-DESIGN-8-NOV-2026.md` (on `feature/ios`) into
something to build against; section 12 lists where it differs.

**Status:** proposed in its own pull request. The relay that implements it is on
`feature/relay`. Changes after review must be additive, or bump the version.

---

## 1. Basics

| | |
| --- | --- |
| Base URL | `https://<relay host>` in production; `http://127.0.0.1:8787` for local development |
| Paths | All start `/v1/`. A breaking change gets `/v2/` |
| Bodies | JSON, encoded with `StandByWire` rules: ISO-8601 dates with milliseconds, optional fields omitted |
| Every response | `X-Protocol-Version: 1` |
| Errors | Non-2xx bodies are `ErrorResponse`: `{"error":{"code":"…","message":"…"}}` (§10) |
| Credentials | `Authorization: Bearer <token>` (§2) |

---

## 2. Credentials

Three kinds, all opaque bearer strings. Clients never parse them.

| Credential | Who holds it | Lets it | Lifetime |
| --- | --- | --- | --- |
| `macToken` | The Mac | Open the Mac socket, upload artwork, make pairing codes, unpair | Until unpaired |
| `phoneToken` | The phone app and its extension | Send commands, read the session, fetch artwork, register push tokens, unpair | Until unpaired or replaced by a new phone |
| `claimSecret` | A phone mid-pairing | Poll its own claim, once | 5 minutes |

- Shape: `msb1.<kind>.<id>.<secret>`, `secret` being 32 random bytes in base64url. The relay
  routes on `<id>` and stores only SHA-256 of the whole token; it compares hashes in constant
  time. Tokens never appear in logs.
- **Mac:** store `macToken` in the login Keychain.
- **Phone:** store `phoneToken` in a shared Keychain access group with
  `kSecAttrAccessibleAfterFirstUnlock`, so the extension can read it while the phone is locked
  on its stand (relay design §5).
- **Revocation:** `DELETE /v1/pairing` from either side destroys both tokens at once. Pairing a
  new phone revokes the previous phone's token.
- A revoked or unknown token gets `401 unauthorized`. Treat it as "pair again"; don't retry.

---

## 3. Endpoints

| Method and path | Credential | Body → success | Notes |
| --- | --- | --- | --- |
| `POST /v1/pairings` | none | `PairingCreateRequest` → `201 PairingCreateResponse` | Mac, once. Rate limited |
| `POST /v1/pairing/code` | mac | — → `201 PairingCodeResponse` | New code each time; earlier code dies |
| `POST /v1/pairing/claim` | none | `PairingClaimRequest` → `202 PairingClaimResponse` | Phone. Rate limited |
| `GET /v1/pairing/claim/{claimID}` | claim | — → `200 PairingClaimStatus` | Poll every 2 s |
| `DELETE /v1/pairing` | mac or phone | — → `204` | Unpairs both sides, ends the session |
| `GET /v1/mac/socket` | mac | WebSocket upgrade → `101` | §5 |
| `PUT /v1/artwork/{artworkID}` | mac | image bytes → `201 ArtworkDescriptor` | §8 |
| `GET /v1/artwork/{pairingID}/{artworkID}?sig=…` | signature or phone | — → `200` image | §8 |
| `GET /v1/session` | phone | — → `200 SessionState` | §6 |
| `POST /v1/commands` | phone | `CommandRequest` → `200 CommandResponse` | §7. Header `Idempotency-Key` |
| `PUT /v1/tokens/start` | phone | `PushToStartTokenRegistration` → `204` | §9 |
| `PUT /v1/tokens/session` | phone | `SessionPushTokenRegistration` → `204` | §9 |
| `DELETE /v1/tokens/session/{sessionID}` | phone | — → `204` | §9 |
| `PUT /v1/tokens/alert` | phone | `{ "token": "<hex>" }` → `204` | §9, reminders on |
| `DELETE /v1/tokens/alert` | phone | — → `204` | §9, reminders off |
| `POST /v1/session/end` | phone | `SessionEndRequest` → `204` | Ends the session now |
| `PUT /v1/tokens/device` | phone | `DeviceTokenRegistration` → `204` | §14. The app's APNs device token |
| `POST /v1/hand-back/status` | phone | `HandBackStatusReport` → `204` | §14 |

---

## 4. Pairing

```
Mac                         Relay                            Phone
 │ POST /v1/pairings ───────▶ (first run only)
 │ ◀── 201 pairingID, macToken
 │ GET /v1/mac/socket (WebSocket, stays open)
 │ POST /v1/pairing/code ───▶
 │ ◀── 201 "472915", expires in 5 min       shows code ──────▶ user types it
 │                          ◀── POST /v1/pairing/claim {code, phone}
 │                          ── 202 claimID, claimSecret, mac ──▶ "Waiting for Studio Mac…"
 │ ◀── pair-request {claimID, phone}         ◀── GET /v1/pairing/claim/{id}  (pending)
 │  user clicks Allow
 │ pair-decision {claimID, approved:true} ─▶
 │ ◀── paired {phone}                        ◀── GET /v1/pairing/claim/{id}
 │                          ── 200 approved, phoneToken ─────▶ stores it; claim is gone
```

- **Codes:** six digits from a CSPRNG, one live code per Mac, five-minute expiry, consumed by
  the first claim. The relay keeps only a hash.
- **Nothing is granted by the code alone.** The claim waits for the person at the Mac. A denial
  answers `{"status":"denied"}` once; an unanswered claim expires with the code.
- **The phone token is handed over once.** After the approved poll, the claim answers `410`.
- **Rate limits:** 5 wrong guesses kill a code. Per client IP: 10 claims a minute, 5 pairing
  creations an hour. Over the limit: `429 rate_limited` with `retryAfter`.
- A Mac that isn't connected when the claim arrives gets the `pair-request` when it next
  connects, if the claim hasn't expired.

---

## 5. Mac WebSocket

```
GET /v1/mac/socket
Authorization: Bearer <macToken>
Upgrade: websocket
```

Frames are `MacFrame` / `RelayFrame` (PROTOCOL.md §6), one JSON object per text message.

| Step | Frames |
| --- | --- |
| Open | Mac → `hello`; relay → `welcome`, then `paired {phone}` if paired, then any pending `pair-request`s |
| Run | Mac → `state` on every visible change; relay → `command`; Mac → `ack`; relay → `artwork-request`; Mac uploads (§8), then → `artwork` |
| Pairing | relay → `pair-request`; Mac → `pair-decision`; relay → `paired` |
| Close | Mac → `goodbye` on a deliberate quit; relay → `revoked` before closing on unpair |

- **The Mac sends `state` right after `welcome`, and again after every reconnect.** A re-send
  keeps its revision. The relay applies a state only if its revision is not lower than the last
  one (PROTOCOL.md §4).
- **No position ticks.** The Mac sends on visible change only: a track, play/pause, seek, or
  session change.
- **One Mac socket per pairing.** A new one replaces the old, which is closed with code `4409`.
- **Close codes:** `1000` normal; `4401` bad credentials; `4409` replaced; `4410` revoked.
  Don't reconnect after `4401` or `4410`.
- **Heartbeat:** the Mac sends a WebSocket ping every 30 s, and treats a missing pong within
  10 s as a drop.
- **Reconnect:** exponential backoff from 1 s to 30 s with ±20 % jitter, reset after a
  connection that lasted a minute. Say `hello` again, then send the current state.

---

## 6. Sessions

The relay owns the Now Playing **session**, and its id is what the phone sees as
`MacPlaybackAttributes.id`. It is a fresh lowercase UUID each time, never reused. It is not
the Mac's `listeningSessionID`.

**One session lasts as long as the pairing.** iOS 27.2 shows a session only once the app has
asked for it while open; a session started by a `start` push exists, takes updates, and stays
hidden (seen on an iPhone, 11 November 2026). So the Mac stopping, quitting or going away
updates the session, showing the last track paused, instead of ending it.

| Event | Relay action |
| --- | --- |
| State `playing`, no session | Start a session: new `sessionID`, `start` push to the push-to-start token |
| Visible change during a session | `update` push to the session token |
| `listeningSessionID` changes | Keep the session |
| State `stopped`, `not_running` or `automation_denied` | Keep the session: `update` push, not playing, with the last track |
| `paused` for any time | Keep the session. `PAUSED_TIMEOUT_MS` above 0 ends it after that long |
| Mac sends `goodbye` | Keep the session: if playing, `update` push as paused at its extrapolated position |
| Mac socket drops without `goodbye` | Wait 60 s for a reconnect, then as `goodbye`. The Mac's next state is pushed even at the same revision |
| `POST /v1/session/end` from the phone | End the session, and start no new one for the same `listeningSessionID`. The next listening session, after a stop or quit, starts as usual |
| `DELETE /v1/pairing` | End the session, revoke both tokens |
| APNs answers `410` or `BadDeviceToken` | Forget that token; if it was the session's, end the session |

`GET /v1/session` returns `SessionState`:
- `sessionID`: the current session, or absent.
- `macConnected`.
- `playback`: the Mac's last state, as sent.
- `attributes`: exactly what a push for this session carries.

The app calls it whenever it comes to the foreground and ends any local session the relay no
longer has (relay design §7).

---

## 7. Commands

```
POST /v1/commands
Authorization: Bearer <phoneToken>
Idempotency-Key: 5C1F7A9E-2B4D-4C61-8E3F-0A9B8C7D6E5F

{"command":{"id":"5C1F…","kind":"next","issuedAt":"…"},"sessionID":"9d0f3c2a-…"}
```

| Answer | When |
| --- | --- |
| `200 {"ack":…}` | The Mac answered. `ack.accepted` may still be false, with `ack.error` saying why (PROTOCOL.md §5) |
| `400 invalid_request` | Malformed, or `Idempotency-Key` ≠ `command.id` |
| `409 session_mismatch` | `sessionID` isn't the current session. The Lock Screen is showing an old session; end it |
| `409 no_session` | There is no session |
| `504 mac_unreachable` | No Mac socket, or no ack within 1.2 s |
| `401 unauthorized` | Bad or revoked `phoneToken` |

- **Value commands (11 November 2026).** `seek` carries `position` (seconds), `setVolume` carries
  `level` (0 to 1) and `selectOutput` carries `outputID` (an `AudioOutput.id` from
  `playback.outputs`). The relay passes them through untouched; the Mac checks them and
  answers `invalid_request` when one is missing. `playback.volume` and `playback.outputs` in
  `GET /v1/session`, and `attributes.volume` in pushes, carry the results. All optional, so an
  older Mac or relay leaves them out.
- **`sessionID` is required.** A command from an old session can't act on a new one.
- **Idempotent.** The relay remembers the last 50 command ids per pairing. A repeat gets the
  first answer and is never forwarded twice, and the Mac also ignores repeats. A retried "next"
  skips one track, not two.
- **Use a 1.5 s client timeout** in the extension, so it never outlasts the relay's 1.2 s.
  Throw on anything but `200` with `accepted: true`.
- The Mac acknowledges as soon as Music takes the command, typically within 50 ms. The new
  state follows separately and reaches the Lock Screen as a push. Don't change the UI
  optimistically.

---

## 8. Artwork

- **Ids** are `ArtworkID`s: SHA-256 of Music's original bytes (PROTOCOL.md §2).
- **Upload, Mac:** `PUT /v1/artwork/{artworkID}` with `Content-Type: image/jpeg` or
  `image/png` and at most 1 MB, which is the relay's cap and below the protocol's 5 MB
  maximum. Answers `201` with the stored `ArtworkDescriptor`, `413 payload_too_large`, or
  `400` if the bytes aren't that image type. The relay asks for unknown ids with
  `artwork-request`; uploading an id it already has is harmless.
- **Retrieval:** `track.artworkURL` in `attributes` is a capability URL,
  `/v1/artwork/{pairingID}/{artworkID}?sig=<base64url HMAC>`, which the extension can fetch
  without a header. The same path also accepts `Authorization: Bearer <phoneToken>` with no
  `sig`. Responses are `Cache-Control: private, max-age=31536000, immutable`. The `sig`
  changes when the pairing does, so old URLs die with it.
- **Artwork not uploaded yet:** the phone learns an id from the same state that makes the
  relay ask the Mac for it, so it can ask first. If the relay sent `artwork-request` for the
  id in the last 10 s and the Mac is connected, the GET waits up to 3 s for the upload,
  answering as soon as it lands, or `404` as soon as the Mac answers `artwork_unavailable`.
  Otherwise an unknown id is `404 not_found` at once. The Mac uploads a new song's artwork
  before sending the state that names it, so this wait is the fallback.
- **Follow-up update:** iOS suspends the extension about a second after each update. After an
  `update` push naming artwork it hasn't pushed for this session before, the relay sends the
  same attributes again after `ARTWORK_FOLLOW_UP_MS` (700 ms), unless a newer revision, another
  session or a new token arrived meanwhile. The extension should start fetching on `update`,
  not wait for the system to ask, and include the artwork id in the content's id.
- **Tracks without artwork:** `attributes.track.artworkID` is `""` and there is no
  `artworkURL`. The iOS type declares `artworkID` non-optional, and a push the system can't
  decode is silently lost.
- **Extension hardening** (audit D4): only fetch `artworkURL`s on the relay's host, with a
  5 s timeout, a 1 MB cap, and an `image/` content type.

---

## 9. Push tokens and APNs

- **Tokens:** `PUT /v1/tokens/start` for the push-to-start token, and `PUT /v1/tokens/session`
  for each session's update token (from inside the extension, keyed by `attributes.id`).
  Tokens are hex, as Apple's examples encode them. Last write wins. A token for a session that
  isn't current is refused with `409 session_mismatch`.
- **Reminders (opt-in).** `PUT /v1/tokens/alert` stores the app's ordinary APNs device token,
  and `DELETE` removes it. While it's stored, the relay sends an alert push when the Mac starts
  playing after at least `REMIND_AFTER_MS` (default 30 minutes) not playing, or when it starts a
  new session. iOS shows a session only once the app has asked while open, so a dismissed player
  stays hidden until the app is opened; nothing tells the relay whether it is showing, so the
  reminder goes out blind. Headers: `apns-push-type: alert`, `apns-topic:
  com.alistairmerritt.MusicStandBy`, `apns-collapse-id: mac-playing` (each replaces the last),
  `apns-expiration: <now + 10 min>`. Body, with no sound:
  `{"aps": {"alert": {"title": "Music playing on <Mac name>", "body": "Tap to show on your Lock Screen."}, "thread-id": "mac-playing", "interruption-level": "time-sensitive", "relevance-score": 1}}`.
  Time Sensitive (since 12 November 2026) so a Focus or a scheduled Summary doesn't hold it
  back, which in StandBy it otherwise did; the app carries the matching entitlement, and the
  person can still turn it off per app or per Focus. A dead token is forgotten.
- **Pushes**, as specified in Apple's *Publishing remote media sessions*:

  | | |
  | --- | --- |
  | Host | `api.sandbox.push.apple.com` (development) or `api.push.apple.com` (production): `APNS_ENVIRONMENT` first; a `400 BadDeviceToken` is tried once in the other, and the one that delivers is kept for the pairing |
  | Headers | `apns-push-type: nowplaying`, `apns-topic: com.alistairmerritt.MusicStandBy.push-type.nowplaying`, `apns-priority: 10`, `apns-expiration: <now + 30 s>` |
  | Auth | ES256 JWT, `kid` = key id, `iss` = team id, refreshed every 20–60 minutes |
  | `start` | To the push-to-start token. `{"aps":{"event":"start","timestamp":<epoch s>,"attributes":<NowPlayingAttributes>}}` |
  | `update` | To the session token, same shape, same `id` |
  | `end` | To the session token. `attributes` is `{"id":"…"}` only |

  Example: `Examples/apns-update-payload.json`. `aps.timestamp` is integer seconds;
  dates inside `attributes` are ISO-8601 strings, as in Apple's examples.
- **The APNs key lives only in the relay's secrets.** Neither app ever sees it.
- **Live APNs since 11 November 2026.** Cloudflare `fetch()` speaks HTTP/2 to APNs (relay
  design §8), so the relay sends pushes itself. Without the APNs secrets (`npm run dev`, the
  tests) it records what it would send instead.
- **The phone decodes `attributes` itself.** iOS 27.2's decoder couldn't read the ISO-8601
  `timestamp` with milliseconds, so the iOS client reads it, and `artworkURL`, as strings. Keep
  them strings.

---

## 10. Errors

`ErrorResponse` bodies use `ErrorCode` (an open set; unknown codes must be tolerated):

| Status | Codes |
| --- | --- |
| 400 | `invalid_request`, `unsupported_protocol_version` |
| 401 | `unauthorized` |
| 404 | `not_found`, `pairing_code_invalid` (unknown, expired or used: indistinguishable on purpose) |
| 409 | `session_mismatch`, `no_session` |
| 410 | `claim_expired` (a claim that expired or was already collected) |
| 413 | `payload_too_large` |
| 429 | `rate_limited`, with `retryAfter` seconds |
| 504 | `mac_unreachable` |

---

## 11. Timing

Every value is a judgement call, and the relay can change them without a version bump.

| | |
| --- | --- |
| Pairing code and claim expiry | 5 minutes |
| Command ack deadline (relay) / client timeout (extension) | 1.2 s / 1.5 s |
| Mac disconnect grace before the phone is told it paused | 60 s |
| Paused before ending the session | Never (`PAUSED_TIMEOUT_MS`, default 0) |
| Update sent again after new artwork | 700 ms (`ARTWORK_FOLLOW_UP_MS`) |
| Mac ping / pong deadline | 30 s / 10 s |
| Mac reconnect backoff | 1 s → 30 s, ±20 % jitter |

---

## 12. Changes from the relay design proposal

| Proposal | Here | Why |
| --- | --- | --- |
| `pair/begin` gives a code and a provisional token | `POST /v1/pairings` once, then `POST /v1/pairing/code` per pairing | The Mac keeps one identity across phones and re-pairs |
| A correct code grants a phone token | The Mac must approve with `pair-decision` | A guessed or overheard code alone grants nothing |
| `POST /v1/commands` body `{command}` | Adds the required `sessionID` | Stops a stale Lock Screen acting on a newer session |
| Artwork `GET /v1/artwork/{sha256}` with a bearer token | Capability URL, or the bearer | The system-facing extension fetches `artworkURL` without headers |
| Mac acks after re-reading Music (about 0.6 s) | Mac acks when Music takes the command | Leaves the extension's budget for the network |
| `{"error":"mac_unreachable"}` | `{"error":{"code":"mac_unreachable"}}` | Room for a message and `retryAfter` |

---

## 13. What the iOS app needs to do

1. Adopt `StandByProtocol` from `main` (PROTOCOL.md §8).
2. A `CommandSender` that does `POST /v1/commands` with the session's `id` and a 1.5 s
   timeout, called from `MacRemoteSession.handle(_:)`. Throw unless the answer is `200` with
   `accepted: true`, and drop the optimistic `MockLibrary` update (audit B1, B2).
3. A real `PushTokenRegistrar` (`PUT /v1/tokens/start`, `PUT /v1/tokens/session`) plus
   `invalidate(sessionID:)` (`DELETE /v1/tokens/session/{id}`).
4. Pairing: `POST /v1/pairing/claim`, then poll `GET /v1/pairing/claim/{id}` while showing
   "Waiting for <Mac name> to allow this iPhone". Store `phoneToken` in the shared Keychain
   group, which needs the `keychain-access-groups` entitlement on both targets.
5. `GET /v1/session` when foregrounded, ending any local session the relay doesn't have.
6. Accept `artworkID: ""` as "no artwork", and only fetch `artworkURL` from the relay's host.

---

## 14. Continue from iPhone (hand-back)

Added 12 November 2026. The Mac can't see what Apple Music on the phone is playing, and can't
pause it, so the phone does the work: the relay wakes the phone's app, which runs its own
Continue on Mac (skip the Mac to the phone's song in the Mac's queue, seek to the phone's
position, play, then pause the phone). Types in `StandByProtocol/HandBack.swift`.

```
Mac   → relay  hand-back-request {requestID}
relay → phone  background push                     relay → Mac  hand-back-status asked
        …no phone status within 5 s…
relay → phone  Time Sensitive notification          relay → Mac  hand-back-status notified
phone → relay  POST /v1/hand-back/status working    relay → Mac  hand-back-status working
phone → relay  POST /v1/hand-back/status done       relay → Mac  hand-back-status done
```

- **The device token.** `PUT /v1/tokens/device` with the app's own APNs token, sent whenever the
  app has one, whatever its reminder setting: a background push needs no notification
  permission. Without one, the relay answers a request with `unreachable` at once.
- **The background push.** `apns-push-type: background`, `apns-priority: 5` (Apple allows no
  higher for it), `apns-topic` the app's bundle id, `apns-expiration` now + 2 minutes. Payload
  `{"aps":{"content-available":1},"handBack":HandBackRequest}`
  ([example](../../Shared/StandByProtocol/Examples/apns-hand-back-background.json)). iOS
  delivers it when it sees fit: usually within seconds, later or never in Low Power Mode, after
  the person swipes the app away, or after several in an hour. The app ignores one that wakes
  it after `expiresAt`.
- **The notification.** If no phone status has arrived 5 s after the background push, the relay
  sends an alert to the same token: "Continue on <Mac>?", Time Sensitive, `thread-id`,
  `category` and `apns-collapse-id` `hand-back`, with the same `handBack` key
  ([example](../../Shared/StandByProtocol/Examples/apns-hand-back-alert.json)). A tap hands
  back however late it comes: the tap is the request. So does the category's Continue on Mac
  button, without opening the app. Apple Watch shows that button, which matters in StandBy: a
  phone there is locked, so with a watch worn and unlocked, iOS sends the notification to the
  watch, not the phone. It needs the app's notification permission.
- **Statuses.** `POST /v1/hand-back/status` with `HandBackStatusReport`; the relay forwards each
  to the Mac as `hand-back-status`, and any phone status stops the notification. The phone sends
  `working` as it starts, then one of `done`, `nothing_playing`, `not_in_queue`, `failed`. The
  relay's own are `asked`, `notified` and `unreachable`. A request is forgotten 2 minutes
  after it was made; a status for any other request id is accepted and dropped.
- **Only one at a time.** A new request replaces the one before.
