# How the iPhone uses the relay

10 November 2026. For the Mac/relay developer and whoever works on the iOS client next.

The contract is [docs/relay/API-v1.md](../relay/API-v1.md), merged into `feature/ios` from PR #2. This file records only how the phone applies it and the choices the contract leaves to the client. All paths and bodies are in `StandByKit/Sources/StandByKit/Relay/`.

## What the phone does

| Step | Call | Made by |
| --- | --- | --- |
| Pair | `POST /v1/pairing/claim`, then `GET /v1/pairing/claim/{id}` every 2 s with the claim secret until approved, denied or expired | App |
| Reconcile | `GET /v1/session` on launch and every 5 s while the app is in the foreground, plus once 0.7 s after an in-app command | App |
| Command | `POST /v1/commands` with the session on screen and `Idempotency-Key`, 1.5 s timeout | Extension, directly; the app for its own buttons |
| Push tokens | `PUT /v1/tokens/start`, `PUT /v1/tokens/session`, `DELETE /v1/tokens/session/{id}` | App and extension |
| Reminders (opt-in) | `PUT /v1/tokens/alert`, `DELETE /v1/tokens/alert` | App |
| Artwork | The signed `artworkURL`, or `/v1/artwork/{pairingID}/{artworkID}` with the bearer | Extension and app |
| Unpair | `DELETE /v1/pairing`, then forgets the credential whatever the answer | App |

`phoneToken` lives in the shared Keychain group with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so the extension reads it while the phone is locked and the main app is suspended or force-quit.

## Choices the contract leaves to the client

- **Only a relay-named session is shown.** With the relay, the app never activates a session until `GET /v1/session` names one, so every command carries an id the relay recognises.
- **`401` on artwork means no artwork.** Everywhere else `401` ends the pairing. A forged or stale `sig` also answers `401`, and must not unpair the phone.
- **`artworkID: ""` means no artwork.** The phone's type keeps the field optional, so `""` and an absent field both decode.
- **"Mac offline" is its own state.** `macConnected: false` keeps the session. The relay ends it after its 60 s grace and the phone follows.
- **Stop Showing doesn't call `POST /v1/session/end`.** It ends the session on the phone and deletes its push token. `session/end` is sticky for the whole listening session, so after it the person couldn't show the same music again until Music stops or quits. The client has `endSession(sessionID:)`, tested but not wired to anything. **Question for you:** is a non-sticky "hide on this phone" worth adding, or should Stop Showing become the sticky dismissal once pushes work?
- **Polling is foreground only.** Without APNs a locked phone's Lock Screen doesn't change after a command. The command still reaches the Mac. This is deliberate: no background polling.

## Checked against the deployed relay

10 November, from this Mac, with the iOS client code running as a stand-in phone and `msbctl` as a second Mac. Music was paused, so no session existed.

| Check | Result |
| --- | --- |
| Claim, wait for the Mac, receive a phone token | Pass, 2.3 s |
| `GET /v1/session` decodes as `SessionState` | Pass |
| `PUT /v1/tokens/start` | Pass |
| `PUT /v1/tokens/session` for another session | Refused, `session_mismatch` |
| Command for another session | Refused before the Mac, `no_session` |
| `DELETE /v1/tokens/session/{id}` | Pass |
| After unpair, the token | `401`, read as a revoked pairing |

Not covered there because nothing was playing: `attributes`, artwork, and an accepted command. Those need the phone; see [DEVICE-TESTING.md](DEVICE-TESTING.md).

## Artwork limits

PNG or JPEG only, decided from the bytes. The extension holds artwork to **1 MB and 800 pixels per side**, because iOS gives it 6 MB of memory. The Mac already uploads 600-pixel JPEGs of about 86 KB, well inside both.
