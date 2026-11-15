# Independent audit — iOS app, branch `feature/ios`

8 November 2026. Commit `486904c`. Reviewer: a second Claude session, no prior
involvement in writing this code.

## What this audit is and isn't

**I did not build the app.** This Mac has no Xcode (`xcode-select -p` is
`/Library/Developer/CommandLineTools`, Swift 6.2 toolchain only), so nothing
importing `NowPlaying` has been compiled here either.

What I did do:

- Read every source file, the entitlements, the extension `Info.plist` and the
  whole `project.pbxproj`.
- Pulled Apple's live NowPlaying documentation (DocC JSON from
  `developer.apple.com/tutorials/data/documentation/nowplaying/`) and compared
  every API call in the app and extension against the published declarations.
- Typechecked `StandByKit` myself, in Swift 6 language mode, against
  MacOSX26.sdk, using the VFS-overlay workaround for the damaged command line
  tools. **It typechecks clean, with no warnings.** That is an independent
  confirmation of part of the STATUS.md claim.
- Tried to run the package tests. `swift test` fails on this Mac before it
  reaches the tests (`Invalid manifest`, `PackageDescription.Package.__allocating_init`
  undefined at link). **I could not verify the "24 tests pass" claim.** I read
  all 24 and they look correct, but nobody has run them since the tools broke.

Every finding below is labelled:

- **[SOURCE]** — read directly out of the code in this worktree.
- **[DOCS]** — checked against Apple's current published documentation.
- **[TEST]** — a hypothesis that needs a real SDK build or a device to settle.

### Headline

The API surface is in much better shape than "never compiled against the real
SDK" would suggest. Every NowPlaying call site matches Apple's published
declarations, including the ones most likely to have been guessed: the
extension point identifier, the `RemoteMediaSessionExtension` shape, the
`MusicContent` / `Artwork` / `ArtworkRepresentation` chain, `MediaCommand`
factories and `.enabled(_:)`, `MediaDevice.DeviceType.desktop`, and
`.playing()` with no explicit rate. I found no definite API mismatch.

The serious problems are not in the API surface. They are in the architecture:
**the extension has no way to reach the Mac**, so the Lock Screen and StandBy
controls — the point of the app — cannot work as built, and nothing ever ends a
session.

---

## A. Critical blockers for compilation or execution

Fewer than expected. Taking these in order of how likely they are to stop the
first build.

### A1. No development team is set — the build stops before any code compiles

**[SOURCE]** All four target configurations (`project.pbxproj:122,143,162,180`)
set `CODE_SIGN_STYLE = Automatic` with no `DEVELOPMENT_TEAM`. Nothing will sign
or install until a team is chosen in both targets.

Already covered in DEVICE-TESTING.md step 3. Noted here only so the checklist in
section E is complete.

### A2. No shared scheme in the project

**[SOURCE]** There is no `MusicStandBy.xcodeproj/xcshareddata/xcschemes/`
directory, and nothing scheme-shaped is tracked in git. Xcode will autocreate
schemes on first open, so this won't block an interactive build, but:

- `xcodebuild -scheme MusicStandBy` will fail until the project has been opened
  once, which matters if this ever goes near CI.
- The autocreated scheme is the first thing to check if the `.appex` doesn't end
  up embedded (see E).

### A3. The `RemoteMediaSessionAttributes` conformance is compiled out on anything that isn't iOS

**[SOURCE]** `StandByKit/Sources/StandByKit/MacPlaybackAttributes.swift:66-68`:

```swift
#if canImport(NowPlaying) && os(iOS)
extension MacPlaybackAttributes: RemoteMediaSessionAttributes {}
#endif
```

**[TEST]** For a device or simulator build this is correct and will resolve. But
`RemoteSessionController` declares `RemoteMediaSession<MacPlaybackAttributes>`
unconditionally (`App/RemoteSessionController.swift:10`), so for any destination
where `os(iOS)` is false the app target fails with "does not conform to
`RemoteMediaSessionAttributes`". That covers Mac Catalyst and — the one that
will actually bite — anything that resolves the package for macOS. If SwiftUI
Previews misbehave, this is the first place to look. `NowPlaying` is available
on macOS 27 too, so the `os(iOS)` half of the condition is doing no useful work;
`#if canImport(NowPlaying)` alone would be safer.

### A4. The extension type relies entirely on associated-type inference

**[DOCS]** `RemoteMediaSessionExtension` declares two associated types,
`Attributes` and `Session: RemoteMediaSessionRepresentable`.
`MusicStandByNowPlayingExtension` (`NowPlayingExtension/MusicStandByNowPlayingExtension.swift`)
declares neither typealias, and `configuration` returns
`RemoteMediaSessionExtensionConfiguration<Self>`, which gives the compiler no
witness for either. Both must be inferred from the single `session(_:)` method.

**[TEST]** Apple's own sample in *Publishing remote media sessions* does exactly
this, so it probably works. If it doesn't, the fix is two lines:

```swift
typealias Attributes = MacPlaybackAttributes
typealias Session = MacRemoteSession
```

### A5. `MediaPlaybackSnapshot` has one documented initialiser, with four parameters

**[DOCS]** The only initialiser Apple publishes is
`init(state:defaultPlaybackRate:elapsedTime:timestamp:)`.
`NowPlayingExtension/MacRemoteSession.swift:54` calls the three-label form,
omitting `defaultPlaybackRate`.

**[DOCS]** Apple's own prose example in *Publishing remote media sessions* also
omits it, so `defaultPlaybackRate` almost certainly has a default value and
this is fine. Flagged only because it is the single call site in the codebase
that doesn't have a byte-for-byte match in Apple's samples. One-line fix if it
fails: pass `defaultPlaybackRate: 1.0`.

### What I checked and found correct

Worth recording so nobody re-checks it:

| Checked | Verdict |
| --- | --- |
| `EXExtensionPointIdentifier` = `com.apple.nowplaying.remote-media` | **[DOCS]** Exact match with Apple's documented value |
| `RemoteMediaSessionExtensionConfiguration(extension: self)` | **[DOCS]** Matches |
| `RemoteMediaSessionRepresentable` members (`id`, `content`, `playbackSnapshot`, `commands`, `devices`, `update(_:)`) | **[DOCS]** All present, all correct types; `playbackSnapshot` is correctly `MediaPlaybackSnapshot?` |
| `pushToken` / `pushTokenUpdates` used without declaring them | **[DOCS]** Correct. They are protocol requirements the framework satisfies; Apple's sample uses them the same way, in an extension on the conforming type. `MacRemoteSession.startObservingPushToken()` is a near-exact copy of Apple's `startObservingPushToken()` |
| `MediaCommand.play/pause/next/previous` + `.enabled(_:)` | **[DOCS]** Correct, including `.enabled` applied after the factory |
| Synchronous closures passed where `() async throws -> Void` is expected | **[DOCS]** Legal. The closures are not `@Sendable`, so they inherit `@MainActor` from the enclosing property and the call to `handle(_:)` needs no `await` |
| `MusicContent(id:songTitle:artistName:albumName:type:duration:artwork:)` | **[DOCS]** Exact match |
| `Artwork(id:) { size in ... }`, `ArtworkRepresentation(data:)` | **[DOCS]** Match; the trailing closure fills `artworkProvider:` |
| `MediaType.audio`, `MediaDuration.finite(_:)` | **[DOCS]** Both exist |
| `MediaDevice(id:name:type:capabilities:)`, `.desktop` | **[DOCS]** Both exist |
| `RemoteMediaSession` API: `start(attributes:)`, `sessions()`, `update(_:)`, `end()`, `requestToBecomeSystemPrimary()`, `isSystemPrimary`, `pushToStartToken`, `pushToStartTokenUpdates` | **[DOCS]** All exist with the signatures used |
| `PBXFileSystemSynchronizedRootGroup`, empty Sources phases, `dstSubfolderSpec = 16` with `$(EXTENSIONS_FOLDER_PATH)`, `com.apple.product-type.extensionkit-extension`, `CodeSignOnCopy` | **[SOURCE]** All correct for a modern ExtensionKit extension. `plutil -lint` passes on the pbxproj and all three plists |
| Bundle ID prefixing (`…MusicStandBy.NowPlaying` under `…MusicStandBy`) | **[SOURCE]** Correct |
| `@executable_path/../../Frameworks` runpath for the `.appex` | **[SOURCE]** Correct for `MusicStandBy.app/Extensions/X.appex/X` |
| `StandByKit` typechecks in Swift 6 mode | **[SOURCE]** Verified by me, clean |

---

## B. Functional concerns — things that will stop this working as a product

### B1. The extension has no path to the Mac. Lock Screen and StandBy controls cannot work. **(Highest priority.)**

**[SOURCE]** `NowPlayingExtension/MacRemoteSession.swift:77-86`. When the system
delivers a command, `handle(_:)` does three things: appends a record to a JSON
file in the App Group, posts a Darwin notification, and mutates `attributes`
optimistically. Nothing goes to the Mac. `AppModel.processCommandsFromExtension()`
(`App/AppModel.swift:188-199`) is what actually forwards to the transport — and
that only runs in the app process.

**[TEST]** Darwin notifications are delivered to running, non-suspended processes
and cannot launch or resume a suspended app. In the scenario the app exists for —
phone locked, on a dock, app long since suspended — the notification goes nowhere
and the file sits unread. The 30-second expiry in `processCommandsFromExtension`
then discards the command when the user next opens the app
(`AppModel.swift:192-195`), which is the right call but means the tap is simply
lost.

Net effect: tapping Pause on the Lock Screen updates the Lock Screen and does
nothing to the Mac, and the two then disagree until the next push.

BACKGROUND-UPDATES.md lists "whether the extension can reach the Mac on the local
network" as an open question. It isn't really open: a suspended app can't proxy,
and an ExtensionKit extension on a locked phone has no route to a Mac on the LAN
it hasn't already established. The extension needs its own outbound path —
realistically an authenticated HTTPS call to the same server that sends the
pushes. That is a design decision, not a code fix, and it should be made before
any more client code is written.

### B2. Next and Previous are silent no-ops with real data

**[SOURCE]** `MockLibrary.applying(_:to:at:)` (`MockLibrary.swift:41`) bails out
and returns the attributes unchanged when the current track id isn't one of the
three mock ids. With real Apple Music track ids that is always. So with the real
transport in place, Next and Previous on the Lock Screen will change nothing on
screen and send nothing to the Mac — no feedback at all. Play and Pause still
flip optimistically, which makes it worse: two of the four controls appear to
work and two appear dead.

The guard itself is correct and is covered by a test
(`unknownTrackLeavesSkipUntouched`). The problem is that the extension's only
model of "what happens next" is a hard-coded list of three invented songs, and
that model ships inside the `.appex`.

### B3. Nothing ever ends a session

**[SOURCE]** `RemoteSessionController.deactivate()` is called from exactly two
places: `AppModel.stopNowPlaying()` and `AppModel.unpair()`. Neither of these
runs when the Mac disconnects, when playback stops, or when the track ends.
`AppModel.handle(_:)` reacts to `.connection(.disconnected)` by updating a label
and nothing else (`AppModel.swift:157-158`).

A remote session therefore stays on the Lock Screen and in Control Centre,
showing the last state the phone saw, after the Mac has been shut down. Apple's
guidance is to call `end()` when playback ends.

### B4. `requestToBecomeSystemPrimary()` is only ever called on activation

**[SOURCE]** `RemoteSessionController.activate(with:)` calls it; `publish(_:)`
does not. **[DOCS]** Apple states the request has no effect from the background.
So the session can lose the primary slot to anything that plays audio locally,
and the only way back is for the user to foreground the app and tap "Refresh Now
Playing". That is correctly described in DEVICE-TESTING.md's "If it doesn't
appear" section, but it is a real usability ceiling, not a diagnostic step: on a
docked phone the user may never foreground the app again.

Worth calling `requestToBecomeSystemPrimary()` from `sceneDidBecomeActive()`
unconditionally when a session already exists, not only when activating.

### B5. The Mac's volume can't be controlled

**[SOURCE]** `MacRemoteSession.devices` passes `capabilities: []`
(`MacRemoteSession.swift:71`). **[DOCS]** `MediaDevice.Capability` offers
`absoluteVolume(_:onChange:)` and `relativeVolume(onIncrement:onDecrement:)`.
A Mac has a volume. This is presumably deliberate for now; it's the obvious next
capability once B1 is solved.

### B6. The artwork provider ignores the requested size

**[SOURCE]** `MacRemoteSession.swift:47` — `Artwork(id: artworkID) { _ in ... }`
discards the `CGSize` the system passes and always returns whatever the cache or
the remote URL holds. Fine for 600px mock art; wasteful once real album art is in
play, and it means the system can't ask for a small representation for an
accessory.

---

## C. Security and reliability

### C1. The extension fetches an arbitrary URL supplied by a push, with no limits

**[SOURCE]** `ArtworkStore.resolve(id:remoteURL:)`
(`SharedContainer.swift:92-101`) does `URLSession.shared.data(from: remoteURL)`
on a `URL` that arrives, untouched, from the `artworkURL` field of a push
payload (`MacPlaybackAttributes.artworkURL`, decoded by the system).

There is no scheme check, no host allow-list, no response size cap, no
content-type check and no timeout. Whatever comes back is written to the App
Group container and then handed to `ArtworkRepresentation(data:)`. So anyone who
can send a push to this device's session token can make the phone issue an
arbitrary outbound request — including to a private address — and can fill the
container.

**[SOURCE]** The filename derivation is safe: `addingPercentEncoding(withAllowedCharacters: .alphanumerics)`
escapes `/` and `.`, so there's no path traversal. Good. But a very long
`artworkID` will produce a filename over the 255-byte limit and the write will
throw.

Minimum fix: require `https`, cap the response (a few MB), set a short timeout,
and reject anything that isn't an image.

### C2. Push tokens are never invalidated, and are shown in full in the UI

**[SOURCE]** `MockPushTokenRegistrar.registerUpdateToken(_:forSessionID:)`
(`PushTokens.swift:44-48`) only ever adds to `tokens.sessions`. Nothing removes
an entry when a session ends — `RemoteSessionController.deactivate()` doesn't
touch the registrar. The file grows for the life of the install, holding tokens
for sessions that no longer exist.

**[DOCS]** Apple is explicit on both `pushToken` and `pushTokenUpdates`:
"invalidate the outdated token promptly so it cannot be reused, and retain the
token only as long as needed". The current design does neither. Since
`PushTokenRegistrar` is named as the one thing a backend has to implement, the
protocol should grow an `invalidate` method now, before a backend is written
against it.

**[SOURCE]** `DiagnosticsView.swift:50-55` renders both token types in full with
`.textSelection(.enabled)`. Tokens are device-scoped identifiers. For a personal
diagnostics screen this is defensible, but it should be truncated (first and
last 8 characters) before this goes anywhere near TestFlight.

**[SOURCE]** Tokens are stored as plain JSON in the App Group container with no
explicit file protection class. `.completeUntilFirstUserAuthentication` is the
default, which is weaker than `.complete`. Low severity, easy to set.

### C3. The transport event loop dies permanently if its task is cancelled

**[SOURCE]** `AppModel.start()` (`AppModel.swift:57-71`) sets `didStart = true`
and then blocks forever on `for await event in transport.events`. It is driven
by `.task { await model.start() }` in `MusicStandByApp.swift:12`. If SwiftUI ever
cancels or re-runs that task — a scene rebuild, a state restoration — the
`for await` ends, `start()` returns, and the next call hits
`guard !didStart else { return }` and does nothing. From that point on the app
receives no playback updates for the rest of the process lifetime, and the Now
Playing session silently freezes on the last state it saw. Nothing in the UI
would show this; `connection` would still read "Connected".

The guard is there to stop double-subscription, which is a real concern for a
single-consumer `AsyncStream`. It needs to be a "stream is being consumed" flag
that is cleared when consumption stops, not a one-shot.

### C4. A failed activation silently discards every subsequent update

**[SOURCE]** `RemoteSessionController.publish(_:)` opens with
`guard let session else { return }` (`RemoteSessionController.swift:39`). If
`activate(with:)` threw — the error is stored in `lastError` and surfaced in
Diagnostics, which is good — `session` stays `nil`, and from then on every
`publish` call is a no-op. `AppModel.handle(_:)` will only retry activation if
`isSceneActive` is true (`AppModel.swift:168`), so on a backgrounded app there is
no recovery path at all until the user foregrounds it.

### C5. Pairing establishes no secret and no identity

**[SOURCE]** `PairingCode` accepts any six ASCII digits; `MockTransport.pair`
accepts everything except `000000`. There is no rate limiting, no shared secret
derived from the exchange and nothing binding the paired Mac to the device
afterwards — `PairedMac` is just an id and a name
(`Temporary/TemporaryProtocol.swift:72-80`).

The brief says not to change the communication protocol, so this is a flag, not a
request. But a six-digit code with unlimited attempts is 10^6, and whatever
replaces `MockTransport` will need the pairing to produce a key that both the
transport and the push backend can authenticate against. If the Mac developer's
shared protocol doesn't define that, it needs to before the backend exists.

### C6. The extension trusts push attributes completely

**[SOURCE]** `MacRemoteSession.update(_:)` applies anything that passes
`shouldBeReplaced(by:)`, which only compares revision and timestamp. There is no
check that the incoming `id` matches the session's own `id`, and no sanity
bound on `duration` or `elapsedTime`. Low severity given the system decodes the
payload, but `guard incoming.id == id` costs nothing.

### C7. The artwork cache never evicts

**[SOURCE]** `ArtworkStore` writes one file per track id and nothing ever deletes
them (`CommandLog.clear()` exists; there's no equivalent for artwork). Over
months of real listening this grows without bound inside the App Group
container.

### C8. Minor

- **[SOURCE]** `AppModel.handledCommandIDs` is a `Set<UUID>` that only ever
  grows. Bounded in practice by the 50-record log, but it's unbounded in
  principle.
- **[SOURCE]** `unpair()` doesn't clear `CommandLog` or the token file, so a
  re-pair starts with the previous Mac's residue.
- **[SOURCE]** `CommandLog.append` is a read-modify-write with no locking. Only
  the extension writes, so there's no race today, but two extension instances
  for two sessions would clobber each other.
- **[SOURCE]** The `AppIcon` asset has a single 1024×1024 entry with no file
  behind it. Harmless for a development build; it will fail App Store validation.

---

## D. The five highest-priority fixes

Ordered by impact, not by effort. The first is a design decision and should be
settled before more code is written.

### 1. Give the extension its own outbound path — `NowPlayingExtension/MacRemoteSession.swift:77-86`

The App Group file plus Darwin notification cannot work when the app is
suspended, which is every case that matters. Decide now whether commands go
Mac ← server ← extension over HTTPS, and define it alongside the push protocol.

Keep the local path as a fast lane for when the app happens to be running, but
make the remote call the primary one:

```swift
private func handle(_ kind: CommandKind) {
    logger.log("Received command: \(kind.rawValue, privacy: .public)")
    attributes = library.applying(kind, to: attributes, at: Date())   // optimistic UI
    try? CommandLog(container: container).append(
        CommandRecord(kind: kind, sessionID: id, receivedAt: Date()))  // fast lane
    CrossProcessSignal.post(AppGroup.commandSignal)
    Task { try? await commandSender.send(kind, sessionID: id) }        // the real path
}
```

`commandSender` should be a protocol alongside `PushTokenRegistrar`, mocked the
same way. Note that `MediaCommand`'s closures are `() async throws -> Void`, so
the framework already gives you somewhere to await this properly — the current
code throws that away by making `handle` synchronous.

### 2. End the session when the Mac goes away — `App/AppModel.swift:155-174`

```swift
case .connection(let state):
    connection = state
    if case .disconnected = state, sessionController.isActive {
        await sessionController.deactivate()
    }
```

And add an `invalidate(sessionID:)` to `PushTokenRegistrar`
(`StandByKit/Sources/StandByKit/PushTokens.swift:20-23`), called from
`RemoteSessionController.deactivate()`, so `tokens.sessions` doesn't accumulate
dead entries. Apple's documentation asks for this explicitly.

### 3. Make the transport loop restartable — `App/AppModel.swift:57-71`

Replace the one-shot `didStart` with a flag that tracks whether the stream is
currently being consumed, and clear it on exit:

```swift
func start() async {
    guard !isConsuming else { return }
    isConsuming = true
    defer { isConsuming = false }
    // … one-time setup guarded separately by didStart …
    for await event in transport.events { await handle(event) }
}
```

Note that `AsyncStream` only supports one consumer, so a restarted loop will need
the transport to hand out a fresh stream — worth settling when `MockTransport` is
replaced.

### 4. Harden the artwork fetch — `StandByKit/Sources/StandByKit/SharedContainer.swift:92-101`

```swift
guard remoteURL.scheme == "https" else { throw TransportError.artworkUnavailable }
var request = URLRequest(url: remoteURL, timeoutInterval: 10)
let (data, response) = try await URLSession.shared.data(for: request)
guard let http = response as? HTTPURLResponse, http.statusCode == 200,
      http.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("image/") == true,
      data.count <= 5_000_000 else { throw TransportError.artworkUnavailable }
```

Also cap the derived filename length, and add an eviction pass that drops cached
art for ids not in the current attributes.

### 5. Recover from a failed activation, and re-assert primary — `App/RemoteSessionController.swift:38-46`, `App/AppModel.swift:75-82`

`publish` should attempt activation rather than returning silently when
`session` is nil, and `sceneDidBecomeActive()` should re-request the primary slot
whenever a session exists, not only when it has just activated:

```swift
func sceneDidBecomeActive() async {
    isSceneActive = true
    pushTokens = registrar.current()
    await processCommandsFromExtension()
    if isNowPlayingEnabled, let attributes {
        await sessionController.activate(with: attributes)   // already re-requests primary
    }
}
```

That path is nearly right already — `activate` reuses an existing session via
`Session.sessions()` and then calls `requestToBecomeSystemPrimary()`. The gap is
only that it's gated on `attributes != nil`, so a session that exists but has no
fresh state never gets its slot back.

---

## E. First-Xcode-build checklist

Do these in order. Record the result of each, because almost none of it has ever
been observed.

**Before building**

1. Confirm the Xcode version actually ships the NowPlaying framework:
   `ls $(xcrun --sdk iphoneos --show-sdk-path)/System/Library/Frameworks | grep -i nowplaying`.
   If it isn't there, nothing below matters.
2. Open the project. Check Xcode doesn't offer to upgrade `objectVersion` 77 in a
   way that rewrites the synchronized folder groups; if it does, accept it and
   confirm all files still appear under both targets.
3. Confirm schemes were autocreated and that **MusicStandBy** builds the
   extension as a dependency (`xcodebuild -list` should now show them).
4. Set a team on **both** targets. If it's a free Personal Team, delete
   `aps-environment` from `Signing/App.entitlements` first.
5. Register `group.com.alistairmerritt.MusicStandBy` against **both** App IDs.

**Compilation — the specific things to watch for**

6. `StandByKit` resolves and builds for the iOS destination, and
   `MacPlaybackAttributes` is seen to conform to `RemoteMediaSessionAttributes`
   in the app target (A3). If previews fail with a conformance error, widen the
   `#if` to `canImport(NowPlaying)` alone.
7. `MusicStandByNowPlayingExtension` compiles without explicit typealiases (A4).
   If not, add the two shown.
8. `MediaPlaybackSnapshot(state:elapsedTime:timestamp:)` accepts three arguments
   (A5). If not, pass `defaultPlaybackRate: 1.0`.
9. `MacRemoteSession` satisfies `RemoteMediaSessionRepresentable` without
   declaring `pushToken` or `pushTokenUpdates`. If the compiler demands them,
   the framework has no default implementations and the push-token design needs
   rethinking — that would be the one finding here that invalidates a whole
   section of BACKGROUND-UPDATES.md.
10. Note every warning under Swift 5 language mode, particularly any
    Sendable or actor-isolation warning in `MacRemoteSession.commands` and in the
    `Artwork` provider closure. Those become errors under Swift 6 and the
    extension will need to move there eventually.

**On device**

11. Run tests 1 to 6 in DEVICE-TESTING.md as written. Don't shortcut test 6 —
    whether a remote session appears in StandBy at all is the single
    unknown that determines whether this app has a reason to exist.
12. In test 2, check specifically whether **play/pause/skip buttons** appear, not
    just metadata. There is an unconfirmed developer-forum report of metadata
    appearing on the iOS 27 Simulator Lock Screen with the transport buttons
    missing, and only after a second lock cycle
    (<https://developer.apple.com/forums/thread/848425>). If you see the same on
    a device, that's a framework problem, not a problem with this code.
13. When you tap Next on the Lock Screen (test 4), check the Mac as well as the
    phone. Expect the phone to update and the Mac to be untouched — that is B1,
    and seeing it confirms the diagnosis.
14. Confirm the `.appex` is at `MusicStandBy.app/Extensions/MusicStandByNowPlaying.appex`
    in the built product, and that Console shows the subsystem
    `com.alistairmerritt.MusicStandBy.NowPlaying` when a command arrives.
15. Lock the phone, leave it for ten minutes, then check whether the session is
    still on the Lock Screen and whether the progress bar has kept moving.
16. Force-quit the app and check whether the session survives, and whether
    commands still reach the extension.

**Once a paid team and an APNs key exist**

17. Send a `start` push to the push-to-start token with Apple's exact payload
    shape and confirm the extension is woken and `session(_:)` is called.
18. Settle the two open questions in BACKGROUND-UPDATES.md properly: whether the
    extension needs its own `aps-environment` (try without first), and whether
    the system decodes `timestamp` as ISO-8601. For the second, send a payload
    with an ISO-8601 string and one with a numeric epoch, and see which produces
    a correct elapsed time on screen.
19. Confirm what happens to a session whose update token has been reused after
    the session ended (C2).

**Logic tests**

20. Run `swift test` from `iPhoneCompanion/StandByKit` on a machine with working
    tools, or run them through the Xcode scheme. The 24 tests have not been
    executed since the command line tools on the authoring Mac broke, so the
    "24 tests pass" line in STATUS.md should be treated as unverified until this
    is done.

---

## F. Test strategy

**[SOURCE]** The 24 tests are well written — real assertions, injected clock, no
sleeps, temporary containers, and a genuinely useful test
(`unknownTrackLeavesSkipUntouched`) that documents B2's behaviour. The coverage
of `StandByKit` logic is good: extrapolation and clamping, the revision gate
including the Mac-restart case, the push payload shape, pairing validation,
the optimistic command model, `MockTransport`, the command log cap, artwork
resolution order and the Darwin signal round trip.

What isn't covered at all:

- **`AppModel`.** The command forwarding path, the 30-second expiry, the
  cold-launch activation branch at `AppModel.swift:168`, and the `didStart` bug
  in C3 — none of it is tested. This is where the reliability bugs are. It is
  testable: `AppModel` already takes an injected `PlaybackTransport`, so the only
  thing standing in the way is that it lives in the app target rather than in
  `StandByKit` and there is no app test target.
- **`RemoteSessionController`.** Untestable as written, because it talks to
  `RemoteMediaSession` directly. Putting a protocol in front of it would make
  the activate/publish/deactivate state machine (C4) testable without a device.
- **`MacRemoteSession`.** The revision gate is tested on `MacPlaybackAttributes`
  but not on the session that calls it, and `handle(_:)` isn't tested at all.
- **There is no test target in the Xcode project.** `StandByKitTests` exists only
  inside the SPM package, so the app and extension have no tests of any kind.

The practical move is to pull `AppModel` into `StandByKit` behind a protocol for
anything UIKit/NowPlaying-shaped. That would put the three reliability bugs in
section C under test without needing Xcode at all — which matters, because this
project is going to spend more time on machines without a device than with one.
