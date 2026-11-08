# Handover — 8 November 2026

For the macOS Claude and the iOS Claude. Branch `feature/ios`, commit `b74702f`.

Two companion documents, both on this branch. This one does not repeat them.

- [`AUDIT-8-NOV-2026.md`](AUDIT-8-NOV-2026.md) — independent review of the iOS app before
  its first build. Sections A–F.
- [`RELAY-DESIGN-8-NOV-2026.md`](RELAY-DESIGN-8-NOV-2026.md) — proposed relay
  architecture. Sections 1–12.

**Read this first.** The make-or-break question for the whole project — does a remote
media session appear in landscape StandBy — can be answered today, with the code that
already exists, a Mac with Xcode 27 and an iPhone on iOS 27. It needs no relay, no
backend, no Mac app and no APNs key, because the iOS app ships a mock transport that
fakes a Mac. Everything in §8 below is held until that test passes.

---

## 1. Current status

| | State |
| --- | --- |
| **Written** | The iOS app, the Now Playing extension, `StandByKit`, the mock transport, pairing UI, diagnostics, the Xcode project, entitlements and the extension `Info.plist`. All on `feature/ios`. |
| **Compiled** | `StandByKit` only — Swift 6 language mode, against the macOS 26 SDK, clean with no warnings. Independently reproduced during the audit. |
| **Tested** | Nothing has been executed. 24 package tests exist and were read and judged correct, but `swift test` fails on the authoring Mac before reaching them (damaged command line tools). The "24 tests pass" line in `STATUS.md` is **unverified**. |
| **Unverified** | Everything else. No part of this project has been built against the iOS SDK, run on a device, or seen on a Lock Screen. The app and extension were typechecked only against a hand-written stand-in for Apple's `NowPlaying` framework. |

**The Mac side does not exist yet.** `origin/feature/macos` and `origin/main` both contain
a README and nothing else. The shared protocol has not landed, so
`StandByKit/Sources/StandByKit/Temporary/` is currently the only definition of
`PlaybackMessage`, `RemoteCommand`, `CommandAck`, `TrackMetadata` and `PairedMac`. It was
written as a stand-in, not as a proposal for the real thing.

---

## 2. The five findings that matter

Full detail and file references in the audit. In priority order.

1. **The extension has no path to the Mac** (audit B1). Commands are written to an App
   Group file and announced with a Darwin notification, which cannot resume a suspended
   app. On a locked, docked phone — the only case this app exists for — a Lock Screen tap
   changes the Lock Screen and nothing else. This is what the relay design answers.
2. **Nothing ever ends a session** (audit B3). `deactivate()` is only reached from Stop
   and Unpair. A dead Mac leaves a live session on the Lock Screen indefinitely.
3. **The transport loop cannot restart** (audit C3). A one-shot `didStart` guard means
   that if SwiftUI cancels the driving task, the app silently stops receiving updates for
   the rest of the process lifetime while still reporting "Connected".
4. **The extension fetches an arbitrary push-supplied URL with no limits** (audit C1). No
   scheme check, host allow-list, size cap, content-type check or timeout.
5. **No API mismatch was found** (audit, headline). Every NowPlaying call site matches
   Apple's published declarations, checked against the live DocC JSON. The five items in
   audit section A are configuration and inference risks, not wrong signatures. Expect the
   first build to fail on signing before it fails on code.

---

## 3. Recommended relay, in brief

Apple's documented shape: the extension talks to a server, the server talks to the Mac
(WWDC26 session 312). The proposal fills that in with the smallest thing that works.

- **One Cloudflare Worker, one Durable Object per pairing, one R2 bucket for artwork.**
- The **Mac holds a WebSocket** to its Durable Object. Commands reach it in milliseconds.
- The **extension makes short authenticated HTTPS POSTs** — documented behaviour, not a
  workaround: Apple's own command samples do `try await client.send(.play)` inside the
  handler.
- The **relay holds the APNs key**, owns the session identifier, and decides
  start / update / end. Neither app reasons about session lifecycle.
- The **relay translates** `PlaybackMessage` → `MacPlaybackAttributes`, so neither side's
  protocol bends to fit the other.
- **Artwork is served from the relay**, which turns the C1 problem into a one-host check.
- Expected cost **$0/month** on free tiers.

Details, payloads and the failure table: relay design §§1–9.

---

## 4. Still proposals, not agreed contracts

Nothing in the relay design has been agreed by anyone. Treat all of it as a draft until
both of you have reviewed it. In particular:

- **The entire relay design.** It was written by a reviewing agent with no prior
  involvement, from the documentation, without a device.
- **The WebSocket envelope** (`{"type":"state","message":…}` and siblings, relay §4). The
  types inside it are the existing ones; the envelope is invented.
- **The endpoint set and JSON shapes** (relay §4).
- **The pairing and token design** (relay §5), including the decision that the phone token
  does not expire on a timer.
- **Cloudflare as the platform** (relay §8). Explicitly gated on a spike that has not been
  run. The fallback is a conventional server behind identical endpoints.
- **Every timing number** — the 1.2 s relay deadline, the 1.5 s extension timeout, the 60 s
  disconnect grace, the 15-minute paused timeout. All chosen by judgement, none measured.
- **`Temporary/TemporaryProtocol.swift`.** A stand-in. The real shared protocol is the Mac
  developer's to define.

The one thing that is **not** a proposal: the extension must reach the Mac through a
server. That is Apple's documented architecture and the audit's B1 rules out the
alternative.

---

## 5. Next tasks — macOS Claude

You are starting from an empty branch. Nothing here depends on the relay existing.

1. **Define and publish the shared protocol on `main`.** This unblocks the iOS side. Start
   from `StandByKit/Sources/StandByKit/Temporary/TemporaryProtocol.swift` as a sketch of
   what the iOS side needs, not as a specification. Decide explicitly how `revision`
   behaves across a Mac restart — the iOS side currently guesses, accepting a lower
   revision only if its timestamp is more than 5 s newer.
2. **Build the Mac companion app**: observe Apple Music, emit `PlaybackMessage` on change,
   apply a `RemoteCommand`, return a `CommandAck`. Local only. No network.
3. **Review the relay design** (§§2, 4, 7) and say where the envelope or the failure
   handling is wrong for how the Mac actually behaves.

Do not build the WebSocket client yet — see §8.

## 6. Next tasks — iOS Claude

1. **Get the first Xcode build** (audit §E, steps 1–10). Report every compile error and
   every warning. This is the only task that matters until it is done.
2. **Run the device tests** (`DEVICE-TESTING.md` tests 1–6, plus audit §E steps 11–16).
   **Test 6 is the proof of concept.** Record the result before anything else is built.
3. **Run the 24 package tests** on a machine with working tools and confirm or correct the
   claim in `STATUS.md`.
4. **Fix audit C3 and B3** — the restartable transport loop and ending the session on
   disconnect. Both are local, both are independent of the relay, and both are reliability
   bugs that will confuse every later test if left in.
5. **Review the relay design** (§§3, 5, 6, 11) and say where it asks the extension to do
   something it cannot.

Do not implement the command sender, the push token registrar or the keychain plumbing
yet — see §8.

---

## 7. What needs Xcode and a physical iPhone

Nothing below can be settled on a machine without them.

- **Does the NowPlaying framework ship in the SDK at all** (audit §E step 1). If not,
  nothing else matters.
- **Does the project build and sign** — a development team must be set on both targets, and
  the App Group registered against both App IDs (audit A1).
- **Does the extension compile** without explicit typealiases, and does
  `MediaPlaybackSnapshot` accept three arguments (audit A4, A5).
- **Does `MacRemoteSession` satisfy `RemoteMediaSessionRepresentable`** without declaring
  `pushToken` and `pushTokenUpdates`. If the compiler demands them, the whole push-token
  design changes.
- **Do the Lock Screen and Control Centre show the session**, with transport buttons and
  not just metadata.
- **Does the session appear in landscape StandBy** — `DEVICE-TESTING.md` test 6.
- **Does it survive** ten minutes locked, and a force-quit of the app.
- **Does the session hold the system primary slot** when nothing plays locally.
- Later, with a paid team and an APNs key: whether a `start` push wakes the extension,
  whether dates decode as ISO-8601, and whether the extension needs its own
  `aps-environment`.

The only item in the relay design that can be settled without a phone is the Cloudflare
APNs spike (relay §8) — half an hour, and it decides the platform.

---

## 8. Do not implement until the StandBy proof of concept succeeds

Test 6 decides whether this app has a reason to exist. If a remote session does not appear
in StandBy, the product is different and most of the following would be wasted.

Hold all of it:

- **The relay itself** — Worker, Durable Object, R2, pairing endpoints, APNs sending.
- **The Mac's WebSocket client** and artwork upload.
- **The iOS command sender**, the real `PushTokenRegistrar`, the shared Keychain item and
  the `keychain-access-groups` entitlement.
- **Volume control** (audit B5) and size-aware artwork (audit B6).
- **The ActivityKit fallback** named in `BACKGROUND-UPDATES.md`. Only worth building if
  test 6 fails, and then as a deliberate change of product, not a patch.
- **Any work on `MockLibrary`.** It is being deleted, not fixed.

Two cheap exceptions, because they de-risk more than they cost and neither is throwaway:

- The **Cloudflare APNs spike** (relay §8). Half an hour, no phone needed, decides the
  platform.
- The **shared protocol** on `main` (§5 task 1). Needed whatever the outcome.
