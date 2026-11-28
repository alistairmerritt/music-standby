import { runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import {
  MacSocket,
  call,
  createMac,
  directoryStub,
  editStorage,
  macDevice,
  newCommandID,
  pairPhone,
  pairingStub,
  phoneDevice,
  playback,
  pushes,
  session,
  waitForRevision,
} from "./helpers";

async function pairedSetup() {
  const { pairingID, macToken } = await createMac();
  const mac = await MacSocket.connect(macToken);
  const phoneToken = await pairPhone(mac, macToken);
  return { pairingID, macToken, mac, phoneToken };
}

/** Paired, playing, with a session and its push token registered. */
async function playingSetup() {
  const setup = await pairedSetup();
  await call("PUT", "/v1/tokens/start", { token: setup.phoneToken, body: { token: "ab".repeat(32) } });
  const state = playback();
  setup.mac.send({ type: "state", message: state });
  const s = await waitForRevision(setup.phoneToken, state.revision);
  await call("PUT", "/v1/tokens/session", { token: setup.phoneToken, body: { sessionID: s.sessionID, token: "cd".repeat(32) } });
  return { ...setup, sessionID: s.sessionID as string, state };
}

function commandBody(sessionID: string | undefined, kind = "next", id = newCommandID()) {
  return { id, body: { command: { id, kind, issuedAt: new Date().toISOString() }, ...(sessionID ? { sessionID } : {}) } };
}

describe("basics", () => {
  it("answers health with the protocol version", async () => {
    const response = await call("GET", "/v1/health");
    expect(response.status).toBe(200);
    expect(response.headers.get("X-Protocol-Version")).toBe("1");
    expect(await response.json()).toEqual({ ok: true, protocolVersion: 1 });
  });

  it("refuses requests without, or with forged, credentials", async () => {
    expect((await call("GET", "/v1/session")).status).toBe(401);
    expect((await call("GET", "/v1/session", { token: "not-a-token" })).status).toBe(401);
    const { pairingID } = await createMac();
    const forged = `msb1.phone.${pairingID}.${"A".repeat(43)}`;
    const response = await call("GET", "/v1/session", { token: forged });
    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ error: { code: "unauthorized" } });
  });

  it("keeps Mac and phone credentials separate", async () => {
    const { macToken, phoneToken } = await pairedSetup();
    expect((await call("GET", "/v1/session", { token: macToken })).status).toBe(404);
    expect((await call("POST", "/v1/pairing/code", { token: phoneToken })).status).toBe(404);
  });
});

describe("pairing", () => {
  it("issues a phone credential only after the Mac approves, and only once", async () => {
    const { macToken } = await createMac();
    const mac = await MacSocket.connect(macToken);
    const code = await (await call("POST", "/v1/pairing/code", { token: macToken })).json<{ code: string; expiresAt: string }>();
    expect(code.code).toMatch(/^\d{6}$/);
    expect(Date.parse(code.expiresAt) - Date.now()).toBeGreaterThan(4 * 60_000);

    const claimResponse = await call("POST", "/v1/pairing/claim", { body: { code: code.code, phone: phoneDevice } });
    expect(claimResponse.status).toBe(202);
    const claim = await claimResponse.json<{ claimID: string; claimSecret: string; mac: { name: string } }>();
    expect(claim.mac.name).toBe("Studio Mac");

    const poll = () => call("GET", `/v1/pairing/claim/${claim.claimID}`, { token: claim.claimSecret });
    expect(await (await poll()).json()).toEqual({ status: "pending" });

    const request = await mac.next("pair-request");
    expect(request.request.phone.name).toBe("Alistair's iPhone");
    mac.send({ type: "pair-decision", claimID: claim.claimID, approved: true });
    await new Promise((r) => setTimeout(r, 50));

    const approved = await (await poll()).json<{ status: string; phoneToken: string }>();
    expect(approved.status).toBe("approved");
    expect(approved.phoneToken).toMatch(/^msb1\.phone\.[0-9a-f]{32}\.[A-Za-z0-9_-]{43}$/);
    expect((await mac.next("paired")).phone.name).toBe("Alistair's iPhone");
    // Handed over once.
    expect((await poll()).status).toBe(410);
    expect((await call("GET", "/v1/session", { token: approved.phoneToken })).status).toBe(200);
  });

  it("gives nothing when the Mac denies", async () => {
    const { macToken } = await createMac();
    const mac = await MacSocket.connect(macToken);
    const { code } = await (await call("POST", "/v1/pairing/code", { token: macToken })).json<{ code: string }>();
    const claim = await (await call("POST", "/v1/pairing/claim", { body: { code, phone: phoneDevice } })).json<any>();
    const request = await mac.next("pair-request");
    mac.send({ type: "pair-decision", claimID: request.request.claimID, approved: false });
    await new Promise((r) => setTimeout(r, 50));
    expect(await (await call("GET", `/v1/pairing/claim/${claim.claimID}`, { token: claim.claimSecret })).json()).toEqual({ status: "denied" });
  });

  it("consumes a code on first use", async () => {
    const { macToken } = await createMac();
    const { code } = await (await call("POST", "/v1/pairing/code", { token: macToken })).json<{ code: string }>();
    expect((await call("POST", "/v1/pairing/claim", { body: { code, phone: phoneDevice } })).status).toBe(202);
    const second = await call("POST", "/v1/pairing/claim", { body: { code, phone: phoneDevice } });
    expect(second.status).toBe(404);
    expect(await second.json()).toEqual({ error: { code: "pairing_code_invalid" } });
  });

  it("refuses an expired code", async () => {
    const { macToken } = await createMac();
    const { code } = await (await call("POST", "/v1/pairing/code", { token: macToken })).json<{ code: string }>();
    await runInDurableObject(directoryStub(), async (_i, state) => {
      for (const [key, value] of await state.storage.list<{ pairingID: string; expiresAt: number }>({ prefix: "code:" })) {
        await state.storage.put(key, { ...value, expiresAt: Date.now() - 1 });
      }
    });
    expect((await call("POST", "/v1/pairing/claim", { body: { code, phone: phoneDevice } })).status).toBe(404);
  });

  it("refuses an expired claim, even if the Mac approves late", async () => {
    const { pairingID, macToken } = await createMac();
    const mac = await MacSocket.connect(macToken);
    const { code } = await (await call("POST", "/v1/pairing/code", { token: macToken })).json<{ code: string }>();
    const claim = await (await call("POST", "/v1/pairing/claim", { body: { code, phone: phoneDevice } })).json<any>();
    await editStorage(pairingID, async (storage) => {
      const claims = (await storage.get<Record<string, any>>("claims"))!;
      claims[claim.claimID].expiresAt = Date.now() - 1;
      await storage.put("claims", claims);
    });
    mac.send({ type: "pair-decision", claimID: claim.claimID, approved: true });
    expect((await mac.next("error")).error.code).toBe("claim_expired");
    expect((await call("GET", `/v1/pairing/claim/${claim.claimID}`, { token: claim.claimSecret })).status).toBe(410);
  });

  it("kills live codes after five wrong guesses", async () => {
    const { macToken } = await createMac();
    const { code } = await (await call("POST", "/v1/pairing/code", { token: macToken })).json<{ code: string }>();
    const wrong = code === "000000" ? "000001" : "000000";
    for (let i = 0; i < 5; i++) {
      await call("POST", "/v1/pairing/claim", { body: { code: wrong, phone: phoneDevice }, headers: { "CF-Connecting-IP": `10.0.0.${i}` } });
    }
    expect((await call("POST", "/v1/pairing/claim", { body: { code, phone: phoneDevice } })).status).toBe(404);
  });

  it("rate-limits claims per address", async () => {
    const statuses: number[] = [];
    for (let i = 0; i < 11; i++) {
      statuses.push((await call("POST", "/v1/pairing/claim", { body: { code: "123456", phone: phoneDevice }, headers: { "CF-Connecting-IP": "203.0.113.9" } })).status);
    }
    expect(statuses.slice(0, 10).every((s) => s === 404)).toBe(true);
    const limited = await call("POST", "/v1/pairing/claim", { body: { code: "123456", phone: phoneDevice }, headers: { "CF-Connecting-IP": "203.0.113.9" } });
    expect(limited.status).toBe(429);
    expect((await limited.json<any>()).error.retryAfter).toBeGreaterThan(0);
  });

  it("delivers a claim made while the Mac was offline when it connects", async () => {
    const { macToken } = await createMac();
    const { code } = await (await call("POST", "/v1/pairing/code", { token: macToken })).json<{ code: string }>();
    await call("POST", "/v1/pairing/claim", { body: { code, phone: phoneDevice } });
    const mac = await MacSocket.connect(macToken);
    expect((await mac.next("pair-request")).request.phone.name).toBe("Alistair's iPhone");
  });

  it("unpairing revokes both credentials and closes the Mac socket", async () => {
    const { macToken, mac, phoneToken } = await pairedSetup();
    expect((await call("DELETE", "/v1/pairing", { token: phoneToken })).status).toBe(204);
    expect((await mac.next("revoked")).reason).toBe("unpaired");
    expect((await mac.waitForClose()).code).toBe(4410);
    expect((await call("GET", "/v1/session", { token: phoneToken })).status).toBe(401);
    expect((await call("POST", "/v1/pairing/code", { token: macToken })).status).toBe(401);
  });
});

describe("playback and sessions", () => {
  it("stores the Mac's state and builds push attributes from it", async () => {
    const { mac, phoneToken, pairingID } = await pairedSetup();
    const outputs = [
      { id: "name:Studio Mac", name: "Studio Mac", kind: "computer", isSelected: true, isAvailable: true },
      { id: "e4:6e:91:c0:a6:d2", name: "Living Room", kind: "homepod", isSelected: false, isAvailable: true },
    ];
    const state = playback({
      track: { id: "pid:A", title: "Song", artist: "Artist", album: "Album", duration: 200, artworkID: "a".repeat(64) },
      volume: 0.4,
      outputs,
    });
    mac.send({ type: "state", message: state });
    const s = await waitForRevision(phoneToken, state.revision);
    expect(s.sessionID).toMatch(/^[0-9a-f-]{36}$/);
    expect(s.macConnected).toBe(true);
    expect(s.playback).toEqual(state);
    expect(s.playback.outputs).toEqual(outputs);
    expect(s.attributes).toMatchObject({
      id: s.sessionID,
      macName: "Studio Mac",
      revision: state.revision,
      isPlaying: true,
      elapsedTime: 12.5,
      timestamp: state.capturedAt,
      track: { id: "pid:A", title: "Song", artworkID: "a".repeat(64) },
      canGoNext: true,
      volume: 0.4,
    });
    expect(s.attributes.outputs).toBeUndefined();
    expect(s.attributes.track.artworkURL).toMatch(new RegExp(`^https://relay\\.test/v1/artwork/${pairingID}/a{64}\\?sig=[A-Za-z0-9_-]{22}$`));
  });

  it("writes artworkID as an empty string when a track has none", async () => {
    const { mac, phoneToken } = await pairedSetup();
    const state = playback();
    mac.send({ type: "state", message: state });
    const s = await waitForRevision(phoneToken, state.revision);
    expect(s.attributes.track.artworkID).toBe("");
    expect(s.attributes.track.artworkURL).toBeUndefined();
  });

  it("ignores a state older than the one it holds", async () => {
    const { mac, phoneToken } = await pairedSetup();
    const newer = playback();
    const older = { ...newer, revision: newer.revision - 5, elapsedTime: 1 };
    mac.send({ type: "state", message: newer });
    await waitForRevision(phoneToken, newer.revision);
    mac.send({ type: "state", message: older });
    await new Promise((r) => setTimeout(r, 50));
    expect((await session(phoneToken)).playback.revision).toBe(newer.revision);
  });

  it("starts a session only when playing, then keeps it through a stop, showing the last track paused", async () => {
    const { mac, phoneToken, sessionID } = await playingSetup();
    const next = playback({ track: { id: "pid:B", title: "Next", artist: "A", album: "B", duration: 100 } });
    mac.send({ type: "state", message: next });
    await waitForRevision(phoneToken, next.revision);
    const stopped = playback({ state: "stopped", isPlaying: false, track: undefined, listeningSessionID: undefined });
    mac.send({ type: "state", message: stopped });
    const s = await waitForRevision(phoneToken, stopped.revision);

    const sent = await pushes(phoneToken);
    expect(sent.map((p) => p.event)).toEqual(["start", "update", "update"]);
    expect(sent[0].payload.aps.attributes.id).toBe(sessionID);
    expect(sent[1].payload.aps.attributes.track.id).toBe("pid:B");
    expect(sent[2].payload.aps.attributes).toMatchObject({ id: sessionID, isPlaying: false, track: { id: "pid:B", title: "Next" } });
    expect(Number.isInteger(sent[2].payload.aps.timestamp)).toBe(true);
    expect(s.sessionID).toBe(sessionID);
    expect(s.attributes.track.id).toBe("pid:B");
  });

  it("does not start a session for a paused Mac", async () => {
    const { mac, phoneToken } = await pairedSetup();
    const paused = playback({ state: "paused", isPlaying: false });
    mac.send({ type: "state", message: paused });
    const s = await waitForRevision(phoneToken, paused.revision);
    expect(s.sessionID).toBeUndefined();
  });

  it("keeps the session when Music quits, and plays on in it after a relaunch", async () => {
    const { mac, phoneToken, sessionID } = await playingSetup();
    const quit = playback({ state: "not_running", isPlaying: false, track: undefined, listeningSessionID: undefined });
    mac.send({ type: "state", message: quit });
    expect((await waitForRevision(phoneToken, quit.revision)).sessionID).toBe(sessionID);
    const relaunched = playback({ listeningSessionID: crypto.randomUUID().toUpperCase() });
    mac.send({ type: "state", message: relaunched });
    const s = await waitForRevision(phoneToken, relaunched.revision);
    expect(s.sessionID).toBe(sessionID);
    expect(s.attributes.isPlaying).toBe(true);
    const sent = await pushes(phoneToken);
    expect(sent.map((p) => p.event)).toEqual(["start", "update", "update"]);
    expect(sent.every((p) => p.payload.aps.attributes.id === sessionID)).toBe(true);
  });

  it("keeps the session across listening sessions", async () => {
    const { mac, phoneToken, sessionID } = await playingSetup();
    const fresh = playback({ listeningSessionID: crypto.randomUUID().toUpperCase() });
    mac.send({ type: "state", message: fresh });
    const s = await waitForRevision(phoneToken, fresh.revision);
    expect(s.sessionID).toBe(sessionID);
  });

  it("holds an update until the session token arrives, then sends it", async () => {
    const { mac, phoneToken } = await pairedSetup();
    const first = playback();
    mac.send({ type: "state", message: first });
    const s = await waitForRevision(phoneToken, first.revision);
    const second = playback({ state: "paused", isPlaying: false });
    mac.send({ type: "state", message: second });
    await waitForRevision(phoneToken, second.revision);
    expect(await pushes(phoneToken)).toEqual([]);
    await call("PUT", "/v1/tokens/session", { token: phoneToken, body: { sessionID: s.sessionID, token: "ef".repeat(32) } });
    const sent = await pushes(phoneToken);
    expect(sent.map((p) => p.event)).toEqual(["update"]);
    expect(sent[0].payload.aps.attributes.isPlaying).toBe(false);
  });

  it("refuses a session token for a session that isn't current", async () => {
    const { phoneToken } = await playingSetup();
    const response = await call("PUT", "/v1/tokens/session", { token: phoneToken, body: { sessionID: crypto.randomUUID(), token: "aa".repeat(32) } });
    expect(response.status).toBe(409);
  });

  it("lets the phone end the session", async () => {
    const { phoneToken, sessionID } = await playingSetup();
    expect((await call("POST", "/v1/session/end", { token: phoneToken, body: { sessionID } })).status).toBe(204);
    expect((await session(phoneToken)).sessionID).toBeUndefined();
    expect((await pushes(phoneToken)).at(-1).event).toBe("end");
  });

  it("keeps a dismissed session ended until the next listening session", async () => {
    const { mac, phoneToken, sessionID, state } = await playingSetup();
    await call("POST", "/v1/session/end", { token: phoneToken, body: { sessionID } });
    const sameListening = playback({ listeningSessionID: state.listeningSessionID, track: { id: "pid:Z", title: "Z", artist: "A", album: "B", duration: 9 } });
    mac.send({ type: "state", message: sameListening });
    expect((await waitForRevision(phoneToken, sameListening.revision)).sessionID).toBeUndefined();
    const nextListening = playback({ listeningSessionID: crypto.randomUUID().toUpperCase() });
    mac.send({ type: "state", message: nextListening });
    const s = await waitForRevision(phoneToken, nextListening.revision);
    expect(s.sessionID).toBeDefined();
    expect(s.sessionID).not.toBe(sessionID);
  });
});

describe("commands", () => {
  it("forwards a command to the Mac and returns its ack", async () => {
    const { mac, phoneToken, sessionID } = await playingSetup();
    const { id, body } = commandBody(sessionID);
    const pending = call("POST", "/v1/commands", { token: phoneToken, body, headers: { "Idempotency-Key": id } });
    const frame = await mac.next("command");
    expect(frame.command).toMatchObject({ id, kind: "next" });
    mac.send({ type: "ack", ack: { commandID: id, accepted: true, revision: 42 } });
    const response = await pending;
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ack: { commandID: id, accepted: true, revision: 42 } });
  });

  it("forwards a value command with its value, and refuses a malformed one", async () => {
    const { mac, phoneToken, sessionID } = await playingSetup();
    const id = newCommandID();
    const body = { command: { id, kind: "seek", issuedAt: new Date().toISOString(), position: 120.5 }, sessionID };
    const pending = call("POST", "/v1/commands", { token: phoneToken, body, headers: { "Idempotency-Key": id } });
    const frame = await mac.next("command");
    expect(frame.command).toEqual(body.command);
    mac.send({ type: "ack", ack: { commandID: id, accepted: true, revision: 43 } });
    expect((await pending).status).toBe(200);
    const bad = newCommandID();
    const r = await call("POST", "/v1/commands", {
      token: phoneToken,
      body: { command: { id: bad, kind: "setVolume", level: "loud" }, sessionID },
      headers: { "Idempotency-Key": bad },
    });
    expect(r.status).toBe(400);
  });

  it("forwards Continue on Mac's playlist as the phone sent it (17 November 2026)", async () => {
    const { mac, phoneToken, sessionID } = await playingSetup();
    const id = newCommandID();
    const command = {
      id, kind: "playStation", issuedAt: new Date().toISOString(), position: 61.5, catalogID: "270246724", title: "Song Sixty",
      playlist: { name: "Road Trip", cloudID: "pl.u-Zx9yW8vU7tS6r", count: 123, index: 59, shuffled: true },
    };
    const pending = call("POST", "/v1/commands", { token: phoneToken, body: { command, sessionID }, headers: { "Idempotency-Key": id } });
    expect((await mac.next("command")).command).toEqual(command);
    mac.send({ type: "ack", ack: { commandID: id, accepted: true, revision: 44 } });
    expect((await pending).status).toBe(200);
  });

  it("forwards Continue on Mac's album as the phone sent it (17 November 2026)", async () => {
    const { mac, phoneToken, sessionID } = await playingSetup();
    const id = newCommandID();
    const command = {
      id, kind: "playStation", issuedAt: new Date().toISOString(), position: 12, catalogID: "1234567890", title: "Song",
      album: { title: "Album", artist: "Artist", count: 38, index: 30, shuffled: true },
    };
    const pending = call("POST", "/v1/commands", { token: phoneToken, body: { command, sessionID }, headers: { "Idempotency-Key": id } });
    expect((await mac.next("command")).command).toEqual(command);
    mac.send({ type: "ack", ack: { commandID: id, accepted: true, revision: 45 } });
    expect((await pending).status).toBe(200);
  });

  it("forwards Continue on Mac's station, library shuffle, repeat and new library playlist as the phone sent them (17 November 2026)", async () => {
    const { mac, phoneToken, sessionID } = await playingSetup();
    const commands = [
      { station: { id: "ra.985484166", name: "Made-Up Radio" }, repeatMode: "all" },
      { shuffledLibrary: true, repeatMode: "one" },
      { playlist: { name: "Today", cloudID: "pl.f4d106fed2bd", count: 50, index: 5, addedToLibrary: true } },
      { positionIsPaused: true },
    ];
    for (const [n, extra] of commands.entries()) {
      const id = newCommandID();
      const command = { id, kind: "playStation", issuedAt: new Date().toISOString(), position: 12, catalogID: "1234567890", title: "Song", ...extra };
      const pending = call("POST", "/v1/commands", { token: phoneToken, body: { command, sessionID }, headers: { "Idempotency-Key": id } });
      expect((await mac.next("command")).command).toEqual(command);
      mac.send({ type: "ack", ack: { commandID: id, accepted: true, revision: 46 + n } });
      expect((await pending).status).toBe(200);
    }
  });

  it("passes the Mac's rejection through", async () => {
    const { mac, phoneToken, sessionID } = await playingSetup();
    const { id, body } = commandBody(sessionID, "play");
    const pending = call("POST", "/v1/commands", { token: phoneToken, body, headers: { "Idempotency-Key": id } });
    await mac.next("command");
    mac.send({ type: "ack", ack: { commandID: id, accepted: false, revision: 7, error: { code: "music_not_running" } } });
    expect(await (await pending).json()).toEqual({ ack: { commandID: id, accepted: false, revision: 7, error: { code: "music_not_running" } } });
  });

  it("never forwards a repeated command id twice", async () => {
    const { mac, phoneToken, sessionID } = await playingSetup();
    const { id, body } = commandBody(sessionID);
    const first = call("POST", "/v1/commands", { token: phoneToken, body, headers: { "Idempotency-Key": id } });
    const concurrent = call("POST", "/v1/commands", { token: phoneToken, body, headers: { "Idempotency-Key": id.toLowerCase() } });
    await mac.next("command");
    mac.send({ type: "ack", ack: { commandID: id, accepted: true, revision: 9 } });
    const later = await call("POST", "/v1/commands", { token: phoneToken, body, headers: { "Idempotency-Key": id } });
    const answers = await Promise.all([first, concurrent].map(async (r) => (await r).json()));
    expect(answers[0]).toEqual(answers[1]);
    expect(await later.json()).toEqual(answers[0]);
    await new Promise((r) => setTimeout(r, 100));
    expect(mac.frames.filter((f) => f.type === "command")).toHaveLength(0);
  });

  it("refuses a command for an earlier session", async () => {
    const { phoneToken } = await playingSetup();
    const { id, body } = commandBody(crypto.randomUUID());
    const response = await call("POST", "/v1/commands", { token: phoneToken, body, headers: { "Idempotency-Key": id } });
    expect(response.status).toBe(409);
    expect((await response.json<any>()).error.code).toBe("session_mismatch");
  });

  it("refuses a command naming a session when there is none", async () => {
    const { phoneToken } = await pairedSetup();
    const a = commandBody(crypto.randomUUID());
    const noSession = await call("POST", "/v1/commands", { token: phoneToken, body: a.body, headers: { "Idempotency-Key": a.id } });
    expect((await noSession.json<any>()).error.code).toBe("no_session");
  });

  it("forwards a command naming no session, with or without one (the app's own actions)", async () => {
    // No session, as once one has ended overnight while the phone had the music.
    const { mac, phoneToken } = await pairedSetup();
    const a = commandBody(undefined, "playStation");
    const pending = call("POST", "/v1/commands", { token: phoneToken, body: a.body, headers: { "Idempotency-Key": a.id } });
    expect((await mac.next("command")).command).toMatchObject({ id: a.id, kind: "playStation" });
    mac.send({ type: "ack", ack: { commandID: a.id, accepted: true, revision: 7 } });
    expect((await pending).status).toBe(200);
    // With a session, too.
    const { mac: mac2, phoneToken: phone2 } = await playingSetup();
    const b = commandBody(undefined);
    const second = call("POST", "/v1/commands", { token: phone2, body: b.body, headers: { "Idempotency-Key": b.id } });
    expect((await mac2.next("command")).command).toMatchObject({ id: b.id, kind: "next" });
    mac2.send({ type: "ack", ack: { commandID: b.id, accepted: true, revision: 8 } });
    expect((await second).status).toBe(200);
  });

  it("refuses a session id that isn't text", async () => {
    const { phoneToken } = await pairedSetup();
    const id = newCommandID();
    const response = await call("POST", "/v1/commands", {
      token: phoneToken, body: { command: { id, kind: "next" }, sessionID: 42 }, headers: { "Idempotency-Key": id },
    });
    expect(response.status).toBe(400);
  });

  it("requires Idempotency-Key to match the command id", async () => {
    const { phoneToken, sessionID } = await playingSetup();
    const { body } = commandBody(sessionID);
    expect((await call("POST", "/v1/commands", { token: phoneToken, body })).status).toBe(400);
    expect((await call("POST", "/v1/commands", { token: phoneToken, body, headers: { "Idempotency-Key": newCommandID() } })).status).toBe(400);
  });

  it("answers 504 when the Mac doesn't acknowledge in time", async () => {
    const { mac, phoneToken, sessionID } = await playingSetup();
    const { id, body } = commandBody(sessionID);
    const started = Date.now();
    const response = await call("POST", "/v1/commands", { token: phoneToken, body, headers: { "Idempotency-Key": id } });
    expect(response.status).toBe(504);
    expect(Date.now() - started).toBeGreaterThanOrEqual(350);
    // A late ack is kept, so a retry gets it without a second send.
    await mac.next("command");
    mac.send({ type: "ack", ack: { commandID: id, accepted: true, revision: 3 } });
    await new Promise((r) => setTimeout(r, 50));
    const retry = await call("POST", "/v1/commands", { token: phoneToken, body, headers: { "Idempotency-Key": id } });
    expect(await retry.json()).toEqual({ ack: { commandID: id, accepted: true, revision: 3 } });
  });

  it("answers 504 at once when the Mac is offline", async () => {
    const { mac, phoneToken, sessionID } = await playingSetup();
    mac.close();
    await new Promise((r) => setTimeout(r, 50));
    const { id, body } = commandBody(sessionID);
    const response = await call("POST", "/v1/commands", { token: phoneToken, body, headers: { "Idempotency-Key": id } });
    expect(response.status).toBe(504);
    expect((await response.json<any>()).error.code).toBe("mac_unreachable");
  });
});

describe("catalogue ID and Up Next", () => {
  it("reach the phone in the session as the Mac sent them, and stay out of pushes", async () => {
    const { mac, phoneToken } = await playingSetup();
    const before = (await pushes(phoneToken)).length;
    const state = playback({
      track: { id: "pid:71F8D70086B0C8D9-5242a41bbfa0", title: "Late Night Tales", artist: "Jon Hopkins", album: "Late Night Tales", duration: 4337.5, catalogID: "1102360418" },
      upNext: [
        { catalogID: "1102359994", title: "Lady Divine", artist: "Alela Diane", duration: 312.3 },
        { title: "Uploaded demo", artist: "Me", duration: 0 },
      ],
      playlist: { name: "Road Trip", count: 123, index: 39 },
      album: { title: "Late Night Tales", artist: "Jon Hopkins", count: 20, index: 3, shuffled: true },
      shuffledLibrary: true,
      fromAppleMusic: true,
      repeatMode: "all",
      shuffled: true,
    });
    mac.send({ type: "state", message: state });
    const s = await waitForRevision(phoneToken, state.revision);
    expect(s.playback.track.catalogID).toBe("1102360418");
    expect(s.playback.upNext).toEqual(state.upNext);
    expect(s.playback.playlist).toEqual(state.playlist);
    for (const key of ["album", "shuffledLibrary", "fromAppleMusic", "repeatMode", "shuffled"] as const) {
      expect(s.playback[key]).toEqual(state[key]);
    }
    const sent = (await pushes(phoneToken)).slice(before);
    expect(sent.length).toBeGreaterThan(0);
    for (const push of sent) {
      expect(push.payload.aps.attributes.track.catalogID).toBeUndefined();
      expect(push.payload.aps.attributes.upNext).toBeUndefined();
      expect(push.payload.aps.attributes.playlist).toBeUndefined();
      expect(push.payload.aps.attributes.album).toBeUndefined();
      expect(push.payload.aps.attributes.repeatMode).toBeUndefined();
      expect(JSON.stringify(push.payload).length).toBeLessThan(4096);
    }
  });
});

describe("artwork follow-up", () => {
  it("pushes an update that brings new artwork again, once", async () => {
    const { mac, phoneToken } = await playingSetup();
    const before = (await pushes(phoneToken)).length;
    const withArt = playback({ track: { id: "pid:A-1", title: "Song", artist: "A", album: "B", duration: 200, artworkID: "c".repeat(64) } });
    mac.send({ type: "state", message: withArt });
    await waitForRevision(phoneToken, withArt.revision);
    await new Promise((r) => setTimeout(r, 900));
    const sent = (await pushes(phoneToken)).slice(before);
    expect(sent.map((p) => p.event)).toEqual(["update", "update"]);
    expect(sent.every((p) => p.payload.aps.attributes.revision === withArt.revision)).toBe(true);
    expect(sent[1].payload.aps.attributes.track.artworkID).toBe("c".repeat(64));
    // Same artwork again (a pause): no follow-up.
    const paused = playback({ state: "paused", isPlaying: false, track: withArt.track });
    mac.send({ type: "state", message: paused });
    await waitForRevision(phoneToken, paused.revision);
    await new Promise((r) => setTimeout(r, 900));
    expect((await pushes(phoneToken)).slice(before).length).toBe(3);
  });

  it("skips the follow-up when a newer state has gone out", async () => {
    const { mac, phoneToken } = await playingSetup();
    const before = (await pushes(phoneToken)).length;
    const withArt = playback({ track: { id: "pid:A-1", title: "Song", artist: "A", album: "B", duration: 200, artworkID: "d".repeat(64) } });
    mac.send({ type: "state", message: withArt });
    await waitForRevision(phoneToken, withArt.revision);
    const next = playback({ track: { id: "pid:B-2", title: "Next", artist: "A", album: "C", duration: 100 } });
    mac.send({ type: "state", message: next });
    await waitForRevision(phoneToken, next.revision);
    await new Promise((r) => setTimeout(r, 900));
    const sent = (await pushes(phoneToken)).slice(before);
    expect(sent.map((p) => p.payload.aps.attributes.revision)).toEqual([withArt.revision, next.revision]);
  });

  describe("after the phone downloads the artwork", () => {
    const jpeg = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 9, 8, 7]);

    /** Playing, then a song with uploaded artwork, its update and the 0.7 s follow-up already pushed. */
    async function songWithArtwork(artworkID: string) {
      const setup = await playingSetup();
      const song = playback({ track: { id: "pid:D-4", title: "Song", artist: "A", album: "B", duration: 200, artworkID } });
      setup.mac.send({ type: "state", message: song });
      expect((await setup.mac.next("artwork-request")).artworkID).toBe(artworkID);
      expect((await call("PUT", `/v1/artwork/${artworkID}`, { token: setup.macToken, raw: jpeg, headers: { "Content-Type": "image/jpeg" } })).status).toBe(201);
      await waitForRevision(setup.phoneToken, song.revision);
      await new Promise((r) => setTimeout(r, 900));
      const download = () => call("GET", `/v1/artwork/${setup.pairingID}/${artworkID}`, { token: setup.phoneToken });
      return { ...setup, song, download, before: (await pushes(setup.phoneToken)).length };
    }

    it("pushes that update again a second later, once per artwork", async () => {
      const { phoneToken, song, download, before } = await songWithArtwork("1".repeat(64));
      expect((await download()).status).toBe(200);
      expect((await download()).status).toBe(200); // the extension often asks twice
      await new Promise((r) => setTimeout(r, 600));
      expect((await pushes(phoneToken)).length).toBe(before); // not yet: the image is still arriving
      await new Promise((r) => setTimeout(r, 700));
      const sent = (await pushes(phoneToken)).slice(before);
      expect(sent).toHaveLength(1);
      expect(sent[0].event).toBe("update");
      expect(sent[0].payload.aps.attributes.revision).toBe(song.revision);
      expect(sent[0].payload.aps.attributes.track.artworkID).toBe("1".repeat(64));
      // Downloading the same artwork later (the app, a relaunch) doesn't push again.
      expect((await download()).status).toBe(200);
      await new Promise((r) => setTimeout(r, 1300));
      expect((await pushes(phoneToken)).length).toBe(before + 1);
    });

    it("doesn't push once a newer state has gone out", async () => {
      const { mac, phoneToken, download, before } = await songWithArtwork("2".repeat(64));
      expect((await download()).status).toBe(200);
      const next = playback({ track: { id: "pid:E-5", title: "Next", artist: "A", album: "C", duration: 100 } });
      mac.send({ type: "state", message: next });
      await waitForRevision(phoneToken, next.revision);
      await new Promise((r) => setTimeout(r, 1300));
      const sent = (await pushes(phoneToken)).slice(before);
      expect(sent.map((p) => p.payload.aps.attributes.revision)).toEqual([next.revision]);
    });

    it("doesn't push for artwork the phone wasn't last pushed", async () => {
      const { mac, macToken, phoneToken, pairingID, before } = await songWithArtwork("3".repeat(64));
      // An older song's artwork, still stored, downloaded again.
      const old = "4".repeat(64);
      const other = playback({ track: { id: "pid:F-6", title: "Old", artist: "A", album: "D", duration: 100, artworkID: old } });
      mac.send({ type: "state", message: other });
      await mac.next("artwork-request");
      await call("PUT", `/v1/artwork/${old}`, { token: macToken, raw: jpeg, headers: { "Content-Type": "image/jpeg" } });
      await waitForRevision(phoneToken, other.revision);
      const back = playback({ track: { id: "pid:D-4", title: "Song", artist: "A", album: "B", duration: 200, artworkID: "3".repeat(64) } });
      mac.send({ type: "state", message: back });
      await waitForRevision(phoneToken, back.revision);
      await new Promise((r) => setTimeout(r, 900));
      const settled = (await pushes(phoneToken)).length;
      expect((await call("GET", `/v1/artwork/${pairingID}/${old}`, { token: phoneToken })).status).toBe(200);
      await new Promise((r) => setTimeout(r, 1300));
      expect((await pushes(phoneToken)).length).toBe(settled);
      expect(settled).toBeGreaterThan(before);
    });
  });
});

describe("reminders", () => {
  const alertToken = "ef".repeat(32);
  const reminders = async (phoneToken: string) => (await pushes(phoneToken)).filter((p) => p.event === "reminder");

  async function pauseFor(pairingID: string, minutes: number) {
    await editStorage(pairingID, async (storage) => {
      const s = (await storage.get<any>("session"))!;
      await storage.put("session", { ...s, pausedSince: Date.now() - minutes * 60_000 });
    });
  }

  it("stores and removes the phone's alert token", async () => {
    const { phoneToken } = await pairedSetup();
    expect((await call("PUT", "/v1/tokens/alert", { token: phoneToken, body: { token: "nothex" } })).status).toBe(400);
    expect((await call("PUT", "/v1/tokens/alert", { token: phoneToken, body: { token: alertToken } })).status).toBe(204);
    expect((await call("DELETE", "/v1/tokens/alert", { token: phoneToken })).status).toBe(204);
  });

  it("reminds the phone when the Mac plays after a break", async () => {
    const { mac, pairingID, phoneToken } = await playingSetup();
    await call("PUT", "/v1/tokens/alert", { token: phoneToken, body: { token: alertToken } });
    const paused = playback({ state: "paused", isPlaying: false });
    mac.send({ type: "state", message: paused });
    await waitForRevision(phoneToken, paused.revision);
    await pauseFor(pairingID, 9);   // past the 8 minutes after which iOS gives StandBy to Apple Music
    const resumed = playback();
    mac.send({ type: "state", message: resumed });
    await waitForRevision(phoneToken, resumed.revision);
    const sent = await reminders(phoneToken);
    expect(sent).toHaveLength(1);
    expect(sent[0].payload).toEqual({
      aps: {
        alert: { title: "Music playing on Studio Mac", body: "Tap to show it on your Lock Screen and in StandBy." },
        "thread-id": "mac-playing",
        "interruption-level": "time-sensitive",
        "relevance-score": 1,
        "content-available": 1,
      },
    });
    expect(sent[0].payload.aps.sound).toBeUndefined();
    expect(sent[0].collapseID).toBe("mac-playing");
    // The Now Playing update goes first, so a tap finds the session current.
    const all = await pushes(phoneToken);
    expect(all.at(-2).event).toBe("update");
    expect(all.at(-1).event).toBe("reminder");
  });

  it("doesn't remind after a short pause, or a phone that didn't ask", async () => {
    const { mac, pairingID, phoneToken } = await playingSetup();
    await call("PUT", "/v1/tokens/alert", { token: phoneToken, body: { token: alertToken } });
    mac.send({ type: "state", message: playback({ state: "paused", isPlaying: false }) });
    await pauseFor(pairingID, 7);   // the player is still showing
    const quick = playback();
    mac.send({ type: "state", message: quick });
    await waitForRevision(phoneToken, quick.revision);
    expect(await reminders(phoneToken)).toHaveLength(0);

    await call("DELETE", "/v1/tokens/alert", { token: phoneToken });
    const paused = playback({ state: "paused", isPlaying: false });
    mac.send({ type: "state", message: paused });
    await waitForRevision(phoneToken, paused.revision);
    await pauseFor(pairingID, 60);
    const later = playback();
    mac.send({ type: "state", message: later });
    await waitForRevision(phoneToken, later.revision);
    expect(await reminders(phoneToken)).toHaveLength(0);
  });

  it("reminds when a new session starts, since a session started by push stays hidden", async () => {
    const { mac, phoneToken } = await pairedSetup();
    await call("PUT", "/v1/tokens/alert", { token: phoneToken, body: { token: alertToken } });
    const first = playback();
    mac.send({ type: "state", message: first });
    await waitForRevision(phoneToken, first.revision);
    expect(await reminders(phoneToken)).toHaveLength(1);
  });

  it("counts a Mac that went away as a break", async () => {
    const { mac, macToken, pairingID, phoneToken, state } = await playingSetup();
    await call("PUT", "/v1/tokens/alert", { token: phoneToken, body: { token: alertToken } });
    mac.close(1001);
    await new Promise((r) => setTimeout(r, 50));
    await editStorage(pairingID, async (storage) => {
      await storage.put("macDisconnectedAt", Date.now() - 61_000);
    });
    await runDurableObjectAlarm(pairingStub(pairingID));
    await pauseFor(pairingID, 45);
    const again = await MacSocket.connect(macToken);
    await again.next("paired");
    again.send({ type: "state", message: { ...state, revision: state.revision + 1 } });
    await new Promise((r) => setTimeout(r, 50));
    expect(await reminders(phoneToken)).toHaveLength(1);
  });
});

describe("paused keep-alive (experiment)", () => {
  // The tests run with PAUSED_KEEP_ALIVE_MS at 5 minutes; the deployed default is off.
  const updates = async (phoneToken: string) => (await pushes(phoneToken)).filter((p) => p.event === "update");

  async function pausedSetup() {
    const setup = await playingSetup();
    const paused = playback({ state: "paused", isPlaying: false });
    setup.mac.send({ type: "state", message: paused });
    await waitForRevision(setup.phoneToken, paused.revision);
    return { ...setup, paused };
  }

  async function backdate(pairingID: string, pausedMinutesAgo: number, keptAliveMinutesAgo: number) {
    await editStorage(pairingID, async (storage) => {
      const s = (await storage.get<any>("session"))!;
      await storage.put("session", { ...s, pausedSince: Date.now() - pausedMinutesAgo * 60_000, keptAliveAt: Date.now() - keptAliveMinutesAgo * 60_000 });
    });
  }

  it("pushes the paused state again once it's due, and not before", async () => {
    const { pairingID, phoneToken, paused } = await pausedSetup();
    const before = (await updates(phoneToken)).length;
    await backdate(pairingID, 4, 4);
    await runDurableObjectAlarm(pairingStub(pairingID));
    expect(await updates(phoneToken)).toHaveLength(before);

    await backdate(pairingID, 6, 6);
    await runDurableObjectAlarm(pairingStub(pairingID));
    const sent = await updates(phoneToken);
    expect(sent).toHaveLength(before + 1);
    expect(JSON.stringify(sent.at(-1).payload)).toContain(`"revision":${paused.revision}`);
    expect(JSON.stringify(sent.at(-1).payload)).toContain(`"isPlaying":false`);

    // Just sent: the next one waits another 5 minutes.
    await runDurableObjectAlarm(pairingStub(pairingID));
    expect(await updates(phoneToken)).toHaveLength(before + 1);
  });

  it("stops an hour into the pause", async () => {
    const { pairingID, phoneToken } = await pausedSetup();
    const before = (await updates(phoneToken)).length;
    await backdate(pairingID, 61, 6);
    await runDurableObjectAlarm(pairingStub(pairingID));
    expect(await updates(phoneToken)).toHaveLength(before);
  });

  it("sends nothing while playing", async () => {
    const { pairingID, phoneToken } = await playingSetup();
    const before = (await updates(phoneToken)).length;
    await editStorage(pairingID, async (storage) => {
      const s = (await storage.get<any>("session"))!;
      await storage.put("session", { ...s, keptAliveAt: Date.now() - 10 * 60_000 });
    });
    await runDurableObjectAlarm(pairingStub(pairingID));
    expect(await updates(phoneToken)).toHaveLength(before);
  });

  it("stays quiet while the phone plays the song after Continue on iPhone, until the Mac plays again", async () => {
    const { mac, pairingID, phoneToken } = await playingSetup();
    const id = newCommandID();
    const sent = call("POST", "/v1/commands", {
      token: phoneToken,
      headers: { "Idempotency-Key": id },
      body: { command: { id, kind: "pause", issuedAt: new Date().toISOString(), reason: "continue_on_phone" } },
    });
    const command = await mac.next("command");
    expect(command.command.reason).toBe("continue_on_phone");
    const paused = playback({ state: "paused", isPlaying: false });
    mac.send({ type: "ack", ack: { commandID: id, accepted: true, revision: paused.revision } });
    await sent;
    mac.send({ type: "state", message: paused });
    await waitForRevision(phoneToken, paused.revision);

    const before = (await updates(phoneToken)).length;
    await backdate(pairingID, 20, 20);
    await runDurableObjectAlarm(pairingStub(pairingID));
    expect(await updates(phoneToken)).toHaveLength(before);

    // Back on the Mac, then paused there: the keep-alive applies again.
    const resumed = playback();
    mac.send({ type: "state", message: resumed });
    await waitForRevision(phoneToken, resumed.revision);
    const pausedAgain = playback({ state: "paused", isPlaying: false });
    mac.send({ type: "state", message: pausedAgain });
    await waitForRevision(phoneToken, pausedAgain.revision);
    const later = (await updates(phoneToken)).length;
    await backdate(pairingID, 6, 6);
    await runDurableObjectAlarm(pairingStub(pairingID));
    expect(await updates(phoneToken)).toHaveLength(later + 1);
  });

  it("sends nothing to a player that was swiped away", async () => {
    const { pairingID, phoneToken, sessionID } = await pausedSetup();
    await backdate(pairingID, 6, 6);
    expect((await call("POST", "/v1/session/end", { token: phoneToken, body: { sessionID } })).status).toBe(204);
    const before = (await updates(phoneToken)).length;
    await runDurableObjectAlarm(pairingStub(pairingID));
    expect(await updates(phoneToken)).toHaveLength(before);
  });
});

describe("connection loss", () => {
  it("keeps the session through a reconnect inside the grace period", async () => {
    const { mac, macToken, phoneToken, sessionID, state } = await playingSetup();
    mac.close(1006 === 1006 ? 1001 : 1000);
    await new Promise((r) => setTimeout(r, 50));
    expect((await session(phoneToken)).macConnected).toBe(false);
    const again = await MacSocket.connect(macToken);
    expect((await again.next("paired")).phone.name).toBe("Alistair's iPhone");
    again.send({ type: "state", message: state });
    await new Promise((r) => setTimeout(r, 50));
    const s = await session(phoneToken);
    expect(s.macConnected).toBe(true);
    expect(s.sessionID).toBe(sessionID);
  });

  it("pushes a Mac that stays away past the grace period as paused, keeps the session, and resumes it", async () => {
    const { mac, macToken, pairingID, phoneToken, sessionID, state } = await playingSetup();
    mac.close(1001);
    await new Promise((r) => setTimeout(r, 50));
    await editStorage(pairingID, async (storage) => {
      await storage.put("macDisconnectedAt", Date.now() - 61_000);
    });
    await runDurableObjectAlarm(pairingStub(pairingID));
    const away = await session(phoneToken);
    expect(away.sessionID).toBe(sessionID);
    const last = (await pushes(phoneToken)).at(-1);
    expect(last.event).toBe("update");
    expect(last.payload.aps.attributes).toMatchObject({ id: sessionID, isPlaying: false, revision: state.revision });
    expect(last.payload.aps.attributes.elapsedTime).toBeGreaterThanOrEqual(state.elapsedTime);
    // Only once.
    await runDurableObjectAlarm(pairingStub(pairingID));
    expect((await pushes(phoneToken)).filter((p) => p.payload.aps.attributes.isPlaying === false)).toHaveLength(1);

    // The Mac comes back and resends the same state: it is pushed, so the phone plays on.
    const again = await MacSocket.connect(macToken);
    await again.next("paired");
    again.send({ type: "state", message: state });
    await new Promise((r) => setTimeout(r, 50));
    const back = (await pushes(phoneToken)).at(-1);
    expect(back.payload.aps.attributes).toMatchObject({ id: sessionID, isPlaying: true, revision: state.revision });
  });

  it("keeps the session on goodbye, pushed as paused", async () => {
    const { mac, phoneToken, sessionID } = await playingSetup();
    mac.send({ type: "goodbye", reason: "app_quit" });
    await new Promise((r) => setTimeout(r, 50));
    const s = await session(phoneToken);
    expect(s.sessionID).toBe(sessionID);
    expect(s.attributes.isPlaying).toBe(false);
    expect((await pushes(phoneToken)).at(-1).payload.aps.attributes.isPlaying).toBe(false);
  });

  // Why the Mac left, so the phone can say Asleep rather than Connected (25 November 2026).
  it("says the Mac is asleep after a sleep goodbye, until it connects again", async () => {
    const { mac, macToken, phoneToken } = await playingSetup();
    expect((await session(phoneToken)).macAway).toBeUndefined();
    mac.send({ type: "goodbye", reason: "sleep" });
    await new Promise((r) => setTimeout(r, 50));
    mac.close(1000);
    await new Promise((r) => setTimeout(r, 50));
    let s = await session(phoneToken);
    expect(s.macConnected).toBe(false);
    expect(s.macAway).toBe("asleep");
    expect(s.attributes.isPlaying).toBe(false);
    const again = await MacSocket.connect(macToken);
    await again.next("paired");
    s = await session(phoneToken);
    expect(s.macConnected).toBe(true);
    expect(s.macAway).toBeUndefined();
  });

  it("says quit after any other goodbye, and lost after a drop without one", async () => {
    const first = await playingSetup();
    first.mac.send({ type: "goodbye", reason: "app_quit" });
    await new Promise((r) => setTimeout(r, 50));
    first.mac.close(1000);
    await new Promise((r) => setTimeout(r, 50));
    expect((await session(first.phoneToken)).macAway).toBe("quit");

    const second = await playingSetup();
    second.mac.close(1001);
    await new Promise((r) => setTimeout(r, 50));
    const s = await session(second.phoneToken);
    expect(s.macConnected).toBe(false);
    expect(s.macAway).toBe("lost");
  });

  it("keeps a session paused for hours by default", async () => {
    const { mac, pairingID, phoneToken, sessionID } = await playingSetup();
    const paused = playback({ state: "paused", isPlaying: false });
    mac.send({ type: "state", message: paused });
    await waitForRevision(phoneToken, paused.revision);
    await editStorage(pairingID, async (storage) => {
      const s = (await storage.get<any>("session"))!;
      await storage.put("session", { ...s, pausedSince: Date.now() - 8 * 3600_000 });
    });
    await runDurableObjectAlarm(pairingStub(pairingID));
    expect((await session(phoneToken)).sessionID).toBe(sessionID);
  });

  it("replaces an older Mac socket with a newer one", async () => {
    const { mac, macToken } = await pairedSetup();
    const newer = await MacSocket.connect(macToken);
    expect((await mac.waitForClose()).code).toBe(4409);
    expect(newer.closed).toBeUndefined();
  });

  it("refuses an unsupported protocol version", async () => {
    const { macToken } = await createMac();
    const mac = await MacSocket.connect(macToken, false);
    mac.send({ type: "hello", protocolVersion: 2, device: { id: "x", name: "x", kind: "mac" } });
    expect((await mac.next("error")).error.code).toBe("unsupported_protocol_version");
  });
});

describe("artwork", () => {
  const jpeg = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3, 4, 5]);
  const id = "b".repeat(64);

  it("asks for unknown artwork, stores the upload and serves it by signed URL", async () => {
    const { mac, macToken, phoneToken, pairingID } = await pairedSetup();
    const state = playback({ track: { id: "pid:C", title: "T", artist: "A", album: "B", duration: 1, artworkID: id } });
    mac.send({ type: "state", message: state });
    expect((await mac.next("artwork-request")).artworkID).toBe(id);

    const put = await call("PUT", `/v1/artwork/${id}`, { token: macToken, raw: jpeg, headers: { "Content-Type": "image/jpeg" } });
    expect(put.status).toBe(201);
    expect(await put.json()).toEqual({ artworkID: id, contentType: "image/jpeg", byteCount: jpeg.byteLength });

    const url = new URL((await waitForRevision(phoneToken, state.revision)).attributes.track.artworkURL);
    const get = await call("GET", `${url.pathname}${url.search}`);
    expect(get.status).toBe(200);
    expect(get.headers.get("Content-Type")).toBe("image/jpeg");
    expect(get.headers.get("Cache-Control")).toContain("immutable");
    expect(new Uint8Array(await get.arrayBuffer())).toEqual(jpeg);

    expect((await call("GET", `/v1/artwork/${pairingID}/${id}`, { token: phoneToken })).status).toBe(200);
    expect((await call("GET", `/v1/artwork/${pairingID}/${id}?sig=AAAAAAAAAAAAAAAAAAAAAA`)).status).toBe(401);
    expect((await call("GET", `/v1/artwork/${pairingID}/${id}`)).status).toBe(401);
    expect((await call("GET", `/v1/artwork/${pairingID}/${"c".repeat(64)}`, { token: phoneToken })).status).toBe(404);
  });

  describe("a GET that arrives before the Mac's upload", () => {
    const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

    async function askedFor(artworkID: string) {
      const setup = await pairedSetup();
      setup.mac.send({ type: "state", message: playback({ track: { id: "pid:P", title: "T", artist: "A", album: "B", duration: 1, artworkID } }) });
      expect((await setup.mac.next("artwork-request")).artworkID).toBe(artworkID);
      return setup;
    }

    it("waits for the upload and serves it", async () => {
      const pending = "d".repeat(64);
      const { macToken, phoneToken, pairingID } = await askedFor(pending);
      const started = Date.now();
      const get = call("GET", `/v1/artwork/${pairingID}/${pending}`, { token: phoneToken });
      await sleep(300);
      expect((await call("PUT", `/v1/artwork/${pending}`, { token: macToken, raw: jpeg, headers: { "Content-Type": "image/jpeg" } })).status).toBe(201);
      const response = await get;
      expect(response.status).toBe(200);
      expect(new Uint8Array(await response.arrayBuffer())).toEqual(jpeg);
      expect(Date.now() - started).toBeLessThan(2000);
    });

    it("answers 404 as soon as the Mac says it has no such artwork", async () => {
      const pending = "e".repeat(64);
      const { mac, phoneToken, pairingID } = await askedFor(pending);
      const started = Date.now();
      const get = call("GET", `/v1/artwork/${pairingID}/${pending}`, { token: phoneToken });
      await sleep(100);
      mac.send({ type: "error", error: { code: "artwork_unavailable", message: pending } });
      expect((await get).status).toBe(404);
      expect(Date.now() - started).toBeLessThan(1500);
    });

    it("does not wait for artwork the Mac was never asked for", async () => {
      const { phoneToken, pairingID } = await pairedSetup();
      const started = Date.now();
      expect((await call("GET", `/v1/artwork/${pairingID}/${"f".repeat(64)}`, { token: phoneToken })).status).toBe(404);
      expect(Date.now() - started).toBeLessThan(500);
    });

    it("gives up after 3 s", async () => {
      const pending = "9".repeat(64);
      const { phoneToken, pairingID } = await askedFor(pending);
      const started = Date.now();
      expect((await call("GET", `/v1/artwork/${pairingID}/${pending}`, { token: phoneToken })).status).toBe(404);
      const waited = Date.now() - started;
      expect(waited).toBeGreaterThanOrEqual(2900);
      expect(waited).toBeLessThan(4500);
    }, 10_000);
  });

  it("refuses uploads that are too large or not what they claim", async () => {
    const { macToken, phoneToken } = await pairedSetup();
    const big = new Uint8Array(1024 * 1024 + 1);
    big.set([0xff, 0xd8, 0xff]);
    expect((await call("PUT", `/v1/artwork/${id}`, { token: macToken, raw: big, headers: { "Content-Type": "image/jpeg" } })).status).toBe(413);
    expect((await call("PUT", `/v1/artwork/${id}`, { token: macToken, raw: jpeg, headers: { "Content-Type": "image/png" } })).status).toBe(400);
    expect((await call("PUT", `/v1/artwork/${id}`, { token: macToken, raw: jpeg, headers: { "Content-Type": "text/html" } })).status).toBe(400);
    expect((await call("PUT", `/v1/artwork/${id}`, { token: phoneToken, raw: jpeg, headers: { "Content-Type": "image/jpeg" } })).status).toBe(404);
  });
});

describe("continue from iPhone (hand-back)", () => {
  const deviceToken = "9a".repeat(32);
  const requestID = () => crypto.randomUUID().toUpperCase();

  async function withDevice() {
    const setup = await playingSetup();
    expect((await call("PUT", "/v1/tokens/device", { token: setup.phoneToken, body: { token: deviceToken } })).status).toBe(204);
    return setup;
  }

  const report = (phoneToken: string, id: string, status: string) =>
    call("POST", "/v1/hand-back/status", { token: phoneToken, body: { requestID: id, status } });

  it("stores the phone's device token, whatever its reminder setting", async () => {
    const { phoneToken } = await pairedSetup();
    expect((await call("PUT", "/v1/tokens/device", { token: phoneToken, body: { token: "nothex" } })).status).toBe(400);
    expect((await call("PUT", "/v1/tokens/device", { token: phoneToken, body: { token: deviceToken } })).status).toBe(204);
  });

  it("wakes the phone, then passes its progress to the Mac, with no notification", async () => {
    const { mac, pairingID, phoneToken } = await withDevice();
    const id = requestID();
    mac.send({ type: "hand-back-request", requestID: id });
    expect(await mac.next("hand-back-status")).toEqual({ type: "hand-back-status", requestID: id, status: "asked" });
    const wake = (await pushes(phoneToken)).filter((p) => p.event === "hand-back");
    expect(wake).toHaveLength(1);
    expect(wake[0].payload.aps).toEqual({ "content-available": 1 });
    expect(wake[0].payload.handBack.requestID).toBe(id);
    expect(Date.parse(wake[0].payload.handBack.expiresAt) - Date.now()).toBeGreaterThan(100_000);

    expect((await report(phoneToken, id, "working")).status).toBe(204);
    expect((await mac.next("hand-back-status")).status).toBe("working");
    // Answered: the deadline passing shows nothing.
    await editStorage(pairingID, async (storage) => {
      const h = (await storage.get<any>("handBack"))!;
      await storage.put("handBack", { ...h, notifyAt: Date.now() - 1 });
    });
    await runDurableObjectAlarm(pairingStub(pairingID));
    expect((await pushes(phoneToken)).filter((p) => p.event === "hand-back-alert")).toHaveLength(0);
    expect((await report(phoneToken, id, "done")).status).toBe(204);
    expect((await mac.next("hand-back-status")).status).toBe("done");
  });

  it("passes the Mac's library choice on to the phone in both pushes, and drops a malformed one", async () => {
    const { mac, pairingID, phoneToken } = await withDevice();
    const id = requestID();
    mac.send({ type: "hand-back-request", requestID: id, library: "add", remember: true });
    expect((await mac.next("hand-back-status")).status).toBe("asked");
    const wake = (await pushes(phoneToken)).filter((p) => p.event === "hand-back");
    expect(wake[0].payload.handBack).toMatchObject({ requestID: id, library: "add", remember: true });
    await editStorage(pairingID, async (storage) => {
      const h = (await storage.get<any>("handBack"))!;
      await storage.put("handBack", { ...h, notifyAt: Date.now() - 1 });
    });
    await runDurableObjectAlarm(pairingStub(pairingID));
    const alert = (await pushes(phoneToken)).filter((p) => p.event === "hand-back-alert");
    expect(alert[0].payload.handBack).toMatchObject({ requestID: id, library: "add", remember: true });
    expect((await mac.next("hand-back-status")).status).toBe("notified");

    const plain = requestID();
    mac.send({ type: "hand-back-request", requestID: plain });
    expect((await mac.next("hand-back-status")).status).toBe("asked");
    const second = (await pushes(phoneToken)).filter((p) => p.event === "hand-back").at(-1)!;
    expect(second.payload.handBack.requestID).toBe(plain);
    expect(second.payload.handBack).not.toHaveProperty("library");
    expect(second.payload.handBack).not.toHaveProperty("remember");

    const bad = requestID();
    mac.send({ type: "hand-back-request", requestID: bad, library: "Add To Library!", remember: "yes" });
    expect((await mac.next("hand-back-status")).status).toBe("asked");
    const third = (await pushes(phoneToken)).filter((p) => p.event === "hand-back").at(-1)!;
    expect(third.payload.handBack.requestID).toBe(bad);
    expect(third.payload.handBack).not.toHaveProperty("library");
    expect(third.payload.handBack).not.toHaveProperty("remember");
  });

  it("shows a notification when the background push gets no answer in time", async () => {
    const { mac, pairingID, phoneToken } = await withDevice();
    const id = requestID();
    mac.send({ type: "hand-back-request", requestID: id });
    await mac.next("hand-back-status");
    await editStorage(pairingID, async (storage) => {
      const h = (await storage.get<any>("handBack"))!;
      await storage.put("handBack", { ...h, notifyAt: Date.now() - 1 });
    });
    await runDurableObjectAlarm(pairingStub(pairingID));
    expect((await mac.next("hand-back-status")).status).toBe("notified");
    const alerts = (await pushes(phoneToken)).filter((p) => p.event === "hand-back-alert");
    expect(alerts).toHaveLength(1);
    expect(alerts[0].collapseID).toBe("hand-back");
    expect(alerts[0].payload.aps).toEqual({
      alert: { title: "Continue on Studio Mac?", body: "Play this song on your Mac from where you are." },
      "thread-id": "hand-back",
      category: "hand-back",
      "interruption-level": "time-sensitive",
      "relevance-score": 1,
    });
    expect(alerts[0].payload.handBack.requestID).toBe(id);
    // Once only.
    await runDurableObjectAlarm(pairingStub(pairingID));
    expect((await pushes(phoneToken)).filter((p) => p.event === "hand-back-alert")).toHaveLength(1);
    // A tap later still reaches the Mac.
    await report(phoneToken, id, "working");
    expect((await mac.next("hand-back-status")).status).toBe("working");
  });

  it("answers unreachable at once without a device token", async () => {
    const { mac, phoneToken } = await playingSetup();
    const id = requestID();
    mac.send({ type: "hand-back-request", requestID: id });
    expect((await mac.next("hand-back-status")).status).toBe("unreachable");
    expect((await pushes(phoneToken)).filter((p) => p.event === "hand-back")).toHaveLength(0);
  });

  it("drops a status for another request, refuses a malformed one, and forgets an old request", async () => {
    const { mac, pairingID, phoneToken } = await withDevice();
    const id = requestID();
    mac.send({ type: "hand-back-request", requestID: id });
    await mac.next("hand-back-status");
    expect((await report(phoneToken, requestID(), "done")).status).toBe(204);
    expect((await report(phoneToken, "not-a-uuid", "done")).status).toBe(400);
    expect((await report(phoneToken, id, "Done!")).status).toBe(400);
    await expect(mac.next("hand-back-status", 200)).rejects.toThrow();
    await editStorage(pairingID, async (storage) => {
      const h = (await storage.get<any>("handBack"))!;
      await storage.put("handBack", { ...h, answered: true, expiresAt: Date.now() - 1 });
    });
    await runDurableObjectAlarm(pairingStub(pairingID));
    expect(await runInDurableObject(pairingStub(pairingID), async (_i, state) => state.storage.get("handBack"))).toBeUndefined();
    expect((await report(phoneToken, id, "done")).status).toBe(204);
    await expect(mac.next("hand-back-status", 200)).rejects.toThrow();
  });

  it("passes the reason on Continue on iPhone's pause through to the Mac", async () => {
    const { mac, phoneToken, sessionID } = await playingSetup();
    const id = newCommandID();
    const command = { id, kind: "pause", issuedAt: new Date().toISOString(), reason: "continue_on_phone" };
    const answer = call("POST", "/v1/commands", { token: phoneToken, headers: { "Idempotency-Key": id }, body: { command, sessionID } });
    const forwarded = await mac.next("command");
    expect(forwarded.command).toEqual(command);
    mac.send({ type: "ack", ack: { commandID: id, accepted: true, revision: 1 } });
    expect((await answer).status).toBe(200);
  });
});

// What the privacy policy promises (16 November 2026).
describe("retention", () => {
  const DAY = 24 * 60 * 60_000;

  it("deletes an address's pairing-attempt count when its window ends, and wakes for the next", async () => {
    const ip = "198.51.100.77";
    await call("POST", "/v1/pairing/claim", { body: { code: "123456", phone: phoneDevice }, headers: { "CF-Connecting-IP": ip } });
    await runInDurableObject(directoryStub(), async (_instance, state) => {
      const counts = await state.storage.list<{ count: number; until: number }>({ prefix: `rate:claim:${ip}:` });
      expect(counts.size).toBe(1);
      const [key, entry] = [...counts][0];
      expect(entry.count).toBe(1);
      // A claim's window is a minute: the alarm is due by then.
      expect(entry.until - Date.now()).toBeLessThanOrEqual(60_000);
      const alarm = await state.storage.getAlarm();
      expect(alarm).not.toBeNull();
      expect(alarm!).toBeLessThanOrEqual(entry.until + 1000);
      await state.storage.put(key, { ...entry, until: Date.now() - 1 });
    });
    await runDurableObjectAlarm(directoryStub());
    await runInDurableObject(directoryStub(), async (_instance, state) => {
      expect((await state.storage.list({ prefix: `rate:claim:${ip}:` })).size).toBe(0);
    });
  });

  it("deletes a count stored before counts carried their window, an hour after it began", async () => {
    const old = `rate:create:2001:db8::7:${Date.now() - 2 * 60 * 60_000}`;
    const recent = `rate:create:2001:db8::8:${Date.now() - 10 * 60_000}`;
    await runInDurableObject(directoryStub(), async (_instance, state) => {
      await state.storage.put({ [old]: 3, [recent]: 1 });
      await state.storage.setAlarm(Date.now() + 60_000);
    });
    await runDurableObjectAlarm(directoryStub());
    await runInDurableObject(directoryStub(), async (_instance, state) => {
      expect(await state.storage.get(old)).toBeUndefined();
      expect(await state.storage.get(recent)).toBe(1);
      // Still held, so the alarm comes back for it.
      expect(await state.storage.getAlarm()).not.toBeNull();
    });
  });

  it("wakes to delete a pairing code when it expires", async () => {
    const { macToken } = await createMac();
    await call("POST", "/v1/pairing/code", { token: macToken });
    await runInDurableObject(directoryStub(), async (_instance, state) => {
      const alarm = await state.storage.getAlarm();
      expect(alarm).not.toBeNull();
      expect(alarm! - Date.now()).toBeLessThanOrEqual(5 * 60_000 + 1000);
    });
  });

  it("deletes a pairing whose Mac has been away for 90 days", async () => {
    const { mac, macToken, pairingID, phoneToken } = await pairedSetup();
    mac.close(1001);
    await new Promise((r) => setTimeout(r, 50));
    await editStorage(pairingID, async (storage) => {
      expect(await storage.getAlarm()).not.toBeNull();
      await storage.put("macLastSeenAt", Date.now() - 90 * DAY - 1000);
    });
    await runDurableObjectAlarm(pairingStub(pairingID));
    expect((await call("GET", "/v1/session", { token: phoneToken })).status).toBe(401);
    expect((await call("POST", "/v1/pairing/code", { token: macToken })).status).toBe(401);
    await editStorage(pairingID, async (storage) => {
      expect((await storage.list()).size).toBe(0);
      expect(await storage.getAlarm()).toBeNull();
    });
  });

  it("keeps a pairing whose Mac was away for less than 90 days, and wakes when the 90 are up", async () => {
    const { mac, pairingID, phoneToken } = await pairedSetup();
    mac.close(1001);
    await new Promise((r) => setTimeout(r, 50));
    const seen = Date.now() - 89 * DAY;
    await editStorage(pairingID, async (storage) => {
      await storage.put("macLastSeenAt", seen);
    });
    await runDurableObjectAlarm(pairingStub(pairingID));
    expect((await call("GET", "/v1/session", { token: phoneToken })).status).toBe(200);
    await editStorage(pairingID, async (storage) => {
      expect(await storage.getAlarm()).toBe(seen + 90 * DAY);
    });
  });

  it("never deletes a pairing while its Mac is connected", async () => {
    const { pairingID, phoneToken } = await pairedSetup();
    await editStorage(pairingID, async (storage) => {
      await storage.put("macLastSeenAt", Date.now() - 365 * DAY);
      await storage.setAlarm(Date.now() + 60_000);
    });
    await runDurableObjectAlarm(pairingStub(pairingID));
    expect((await call("GET", "/v1/session", { token: phoneToken })).status).toBe(200);
  });

  it("deletes a pairing whose Mac never connected, 90 days after it was made", async () => {
    const { macToken, pairingID } = await createMac();
    await editStorage(pairingID, async (storage) => {
      const record = (await storage.get<{ createdAt: number }>("record"))!;
      expect(await storage.getAlarm()).toBe(record.createdAt + 90 * DAY);
      await storage.put("record", { ...record, createdAt: Date.now() - 90 * DAY - 1000 });
    });
    await runDurableObjectAlarm(pairingStub(pairingID));
    expect((await call("POST", "/v1/pairing/code", { token: macToken })).status).toBe(401);
  });

  it("keeps device names out of the logs", async () => {
    const logged: string[] = [];
    const original = console.log;
    console.log = (...args: unknown[]) => {
      logged.push(args.map(String).join(" "));
    };
    try {
      const { mac } = await pairedSetup();
      mac.close(1000);
      await new Promise((r) => setTimeout(r, 50));
    } finally {
      console.log = original;
    }
    expect(logged.length).toBeGreaterThan(0);
    for (const line of logged) {
      expect(line).not.toContain(macDevice.name);
      expect(line).not.toContain(phoneDevice.name);
    }
  });
});

describe("live activity (experiment)", () => {
  const startToken = "a1".repeat(32);
  const alertToken = "ef".repeat(32);
  const activityToken = "b2".repeat(32);
  const lowSun = { id: "pid:0000000000000001", title: "Low Sun", artist: "Drift Hotel", album: "Golden Hour", duration: 214, artworkID: "c".repeat(64) };
  const smallHours = { id: "pid:0000000000000002", title: "Small Hours", artist: "Fen Lights", album: "Lit Windows", duration: 252 };
  const activityPushes = async (phoneToken: string) => (await pushes(phoneToken)).filter((p) => String(p.event).startsWith("activity-"));

  async function pauseFor(pairingID: string, minutes: number) {
    await editStorage(pairingID, async (storage) => {
      const s = (await storage.get<any>("session"))!;
      await storage.put("session", { ...s, pausedSince: Date.now() - minutes * 60_000 });
    });
  }

  /** Playing Low Sun, paused for 9 minutes, then playing again: the card starts. */
  async function cardStarted() {
    const setup = await playingSetup();
    const { mac, pairingID, phoneToken } = setup;
    await call("PUT", "/v1/tokens/alert", { token: phoneToken, body: { token: alertToken } });
    await call("PUT", "/v1/tokens/activity-start", { token: phoneToken, body: { token: startToken } });
    const paused = playback({ state: "paused", isPlaying: false, track: lowSun });
    mac.send({ type: "state", message: paused });
    await waitForRevision(phoneToken, paused.revision);
    await pauseFor(pairingID, 9);
    const resumed = playback({ track: lowSun, elapsedTime: 40 });
    mac.send({ type: "state", message: resumed });
    await waitForRevision(phoneToken, resumed.revision);
    const start = (await activityPushes(phoneToken)).find((p) => p.event === "activity-start");
    return { ...setup, start, activityID: start?.sessionID as string };
  }

  it("stores and removes the phone's push-to-start token", async () => {
    const { phoneToken } = await pairedSetup();
    expect((await call("PUT", "/v1/tokens/activity-start", { token: phoneToken, body: { token: "nothex" } })).status).toBe(400);
    expect((await call("PUT", "/v1/tokens/activity-start", { token: phoneToken, body: { token: startToken } })).status).toBe(204);
    expect((await call("DELETE", "/v1/tokens/activity-start", { token: phoneToken })).status).toBe(204);
  });

  it("starts the card instead of the reminder when the Mac plays after a break", async () => {
    const { phoneToken, start } = await cardStarted();
    expect(start).toBeDefined();
    expect(start.priority).toBe(10);
    const aps = start.payload.aps;
    expect(aps.event).toBe("start");
    expect(aps["attributes-type"]).toBe("MacPlaybackActivityAttributes");
    expect(aps.attributes).toEqual({ activityID: start.sessionID, macName: "Studio Mac" });
    expect(aps.alert).toEqual({ title: "Music playing on Studio Mac", body: "Play, pause and skip from your Lock Screen." });
    expect(aps.sound).toBeUndefined();
    expect(aps["input-push-token"]).toBe(1);
    expect(aps["stale-date"]).toBe(aps.timestamp + 30 * 60);
    expect(aps["content-state"]).toMatchObject({
      title: "Low Sun", artist: "Drift Hotel", album: "Golden Hour", artworkID: "c".repeat(64),
      isPlaying: true, elapsed: 40, duration: 214, canGoNext: true,
    });
    expect(typeof aps["content-state"].capturedAt).toBe("number");
    expect((await pushes(phoneToken)).filter((p) => p.event === "reminder")).toHaveLength(0);
  });

  it("falls back to the reminder for a phone without the card", async () => {
    const { mac, pairingID, phoneToken } = await playingSetup();
    await call("PUT", "/v1/tokens/alert", { token: phoneToken, body: { token: alertToken } });
    const paused = playback({ state: "paused", isPlaying: false });
    mac.send({ type: "state", message: paused });
    await waitForRevision(phoneToken, paused.revision);
    await pauseFor(pairingID, 9);
    const resumed = playback();
    mac.send({ type: "state", message: resumed });
    await waitForRevision(phoneToken, resumed.revision);
    expect(await activityPushes(phoneToken)).toHaveLength(0);
    expect((await pushes(phoneToken)).filter((p) => p.event === "reminder")).toHaveLength(1);
  });

  it("updates the card for what it shows, once the phone sends its token", async () => {
    const { mac, phoneToken, activityID } = await cardStarted();
    expect((await call("PUT", "/v1/tokens/activity", { token: phoneToken, body: { activityID: "other", token: activityToken } })).status).toBe(409);
    expect((await call("PUT", "/v1/tokens/activity", { token: phoneToken, body: { activityID, token: activityToken } })).status).toBe(204);
    const before = (await activityPushes(phoneToken)).length;

    // A seek on the same song: nothing the card shows changes.
    const seek = playback({ track: lowSun, elapsedTime: 90 });
    mac.send({ type: "state", message: seek });
    await waitForRevision(phoneToken, seek.revision);
    expect(await activityPushes(phoneToken)).toHaveLength(before);

    // Another song: an update at once, to the card's own token.
    const next = playback({ track: smallHours });
    mac.send({ type: "state", message: next });
    await waitForRevision(phoneToken, next.revision);
    const sent = (await activityPushes(phoneToken)).slice(before);
    expect(sent).toHaveLength(1);
    expect(sent[0].event).toBe("activity-update");
    expect(sent[0].priority).toBe(10);
    expect(sent[0].payload.aps["content-state"]).toMatchObject({ title: "Small Hours", artist: "Fen Lights", artworkID: "", isPlaying: true });

    // Pause: shown as paused.
    const paused = playback({ state: "paused", isPlaying: false, track: smallHours });
    mac.send({ type: "state", message: paused });
    await waitForRevision(phoneToken, paused.revision);
    const last = (await activityPushes(phoneToken)).at(-1);
    expect(last.event).toBe("activity-update");
    expect(last.payload.aps["content-state"].isPlaying).toBe(false);
  });

  it("catches the card up when its token arrives after a change", async () => {
    const { mac, phoneToken, activityID } = await cardStarted();
    const next = playback({ track: smallHours });
    mac.send({ type: "state", message: next });
    await waitForRevision(phoneToken, next.revision);
    const before = (await activityPushes(phoneToken)).length;   // no token yet: nothing sent
    await call("PUT", "/v1/tokens/activity", { token: phoneToken, body: { activityID, token: activityToken } });
    const sent = (await activityPushes(phoneToken)).slice(before);
    expect(sent).toHaveLength(1);
    expect(sent[0].payload.aps["content-state"].title).toBe("Small Hours");
  });

  /** The card started `minutes` ago, as after a long break. */
  async function ageCard(pairingID: string, minutes: number) {
    await editStorage(pairingID, async (storage) => {
      const card = await storage.get<any>("activity");
      if (card) await storage.put("activity", { ...card, startedAt: Date.now() - minutes * 60_000 });
    });
  }

  it("replaces the card after the next break, ending the old one", async () => {
    const { mac, pairingID, phoneToken, activityID } = await cardStarted();
    await call("PUT", "/v1/tokens/activity", { token: phoneToken, body: { activityID, token: activityToken } });
    const paused = playback({ state: "paused", isPlaying: false, track: lowSun });
    mac.send({ type: "state", message: paused });
    await waitForRevision(phoneToken, paused.revision);
    await pauseFor(pairingID, 20);
    await ageCard(pairingID, 21);
    const again = playback({ track: lowSun });
    mac.send({ type: "state", message: again });
    await waitForRevision(phoneToken, again.revision);
    const [end, start] = (await activityPushes(phoneToken)).slice(-2);
    expect(end.event).toBe("activity-end");
    expect(end.sessionID).toBe(activityID);
    expect(end.payload.aps["dismissal-date"]).toBe(end.payload.aps.timestamp);
    expect(start.event).toBe("activity-start");
    expect(start.sessionID).not.toBe(activityID);
  });

  it("starts the card when the phone asks, without the reminder", async () => {
    const { phoneToken } = await playingSetup();
    expect((await call("POST", "/v1/activity/start", { token: phoneToken, body: {} })).status).toBe(409);   // no card token yet
    await call("PUT", "/v1/tokens/alert", { token: phoneToken, body: { token: alertToken } });
    await call("PUT", "/v1/tokens/activity-start", { token: phoneToken, body: { token: startToken } });
    expect((await call("POST", "/v1/activity/start", { token: phoneToken, body: {} })).status).toBe(204);
    const sent = await activityPushes(phoneToken);
    expect(sent.map((p) => p.event)).toEqual(["activity-start"]);
    expect(sent[0].payload.aps["content-state"].title).toBe("Losing My Edge");
    expect((await pushes(phoneToken)).filter((p) => p.event === "reminder")).toHaveLength(0);
  });

  it("only the phone may ask for the card", async () => {
    const { macToken } = await playingSetup();
    expect((await call("POST", "/v1/activity/start", { body: {} })).status).toBe(401);
    expect((await call("POST", "/v1/activity/start", { token: macToken, body: {} })).status).toBe(404);
  });

  it("with the app open, lets the phone start the card itself and then updates it", async () => {
    const { mac, phoneToken, sessionID } = await playingSetup();
    const response = await call("POST", "/v1/activity/start", { token: phoneToken, body: { local: true } });   // no push-to-start token needed
    expect(response.status).toBe(200);
    const grant = (await response.json()) as { attributes: { activityID: string; macName: string }; content: { title: string } };
    expect(grant.attributes.macName).toBe("Studio Mac");
    expect(grant.content.title).toBe("Losing My Edge");
    expect(await activityPushes(phoneToken)).toHaveLength(0);   // nothing pushed: the phone starts it
    const { activityID } = grant.attributes;
    expect((await call("PUT", "/v1/tokens/activity", { token: phoneToken, body: { activityID, token: activityToken } })).status).toBe(204);
    expect(await activityPushes(phoneToken)).toHaveLength(0);   // nothing changed since: no catch-up
    const next = playback({ track: smallHours });
    mac.send({ type: "state", message: next });
    const state = await waitForRevision(phoneToken, next.revision);
    expect(state.sessionID).toBe(sessionID);
    const sent = await activityPushes(phoneToken);
    expect(sent.map((p) => p.event)).toEqual(["activity-update"]);
    expect(sent[0].sessionID).toBe(activityID);
  });

  it("asked fresh with the app open, starts a new Now Playing session and grants the card", async () => {
    const { phoneToken, sessionID } = await playingSetup();
    const before = (await pushes(phoneToken)).length;
    const response = await call("POST", "/v1/activity/start", { token: phoneToken, body: { fresh: true, local: true } });
    expect(response.status).toBe(200);
    const sent = (await pushes(phoneToken)).slice(before);
    expect(sent.map((p) => p.event)).toEqual(["end", "start"]);
    expect(sent[1].sessionID).not.toBe(sessionID);
  });

  it("refuses when nothing is playing", async () => {
    const { phoneToken } = await pairedSetup();
    await call("PUT", "/v1/tokens/activity-start", { token: phoneToken, body: { token: startToken } });
    const response = await call("POST", "/v1/activity/start", { token: phoneToken, body: {} });
    expect(response.status).toBe(409);
    expect(await response.json()).toEqual({ error: { code: "nothing_playing" } });
  });

  it("asked fresh, ends the Now Playing session and push-starts a new one with the card", async () => {
    const { phoneToken, sessionID } = await playingSetup();
    await call("PUT", "/v1/tokens/activity-start", { token: phoneToken, body: { token: startToken } });
    const before = (await pushes(phoneToken)).length;
    expect((await call("POST", "/v1/activity/start", { token: phoneToken, body: { fresh: true } })).status).toBe(204);
    const sent = (await pushes(phoneToken)).slice(before);
    expect(sent.map((p) => p.event)).toEqual(["end", "start", "activity-start"]);
    expect(sent[0].sessionID).toBe(sessionID);
    expect(sent[1].sessionID).not.toBe(sessionID);   // the same ID came back on screen (24 November 2026)
    expect(sent.filter((p) => p.event === "reminder")).toHaveLength(0);
  });

  // MARK: Two cards for one song (26 November 2026)

  it("keeps a card it started moments ago rather than starting a second", async () => {
    const { mac, pairingID, phoneToken, activityID } = await cardStarted();
    const paused = playback({ state: "paused", isPlaying: false, track: lowSun });
    mac.send({ type: "state", message: paused });
    await waitForRevision(phoneToken, paused.revision);
    await pauseFor(pairingID, 9);
    const again = playback({ track: lowSun });
    mac.send({ type: "state", message: again });
    await waitForRevision(phoneToken, again.revision);
    const starts = (await activityPushes(phoneToken)).filter((p) => p.event === "activity-start");
    expect(starts.map((p) => p.sessionID)).toEqual([activityID]);
    expect((await pushes(phoneToken)).filter((p) => p.event === "reminder")).toHaveLength(0);
  });

  it("knows a card before its start push goes, so a token that beats APNs' answer is accepted", async () => {
    const { phoneToken, start, activityID } = await cardStarted();
    expect(start.knownToRelay).toBe(true);
    expect((await call("PUT", "/v1/tokens/activity", { token: phoneToken, body: { activityID, token: activityToken } })).status).toBe(204);
  });

  it("forgets a card whose start push is refused, and sends the reminder", async () => {
    const { mac, pairingID, phoneToken } = await playingSetup();
    await call("PUT", "/v1/tokens/alert", { token: phoneToken, body: { token: alertToken } });
    await call("PUT", "/v1/tokens/activity-start", { token: phoneToken, body: { token: startToken } });
    const paused = playback({ state: "paused", isPlaying: false, track: lowSun });
    mac.send({ type: "state", message: paused });
    await waitForRevision(phoneToken, paused.revision);
    await pauseFor(pairingID, 9);
    await editStorage(pairingID, async (storage) => storage.put("mockDeadTokens", [startToken]));
    const resumed = playback({ track: lowSun });
    mac.send({ type: "state", message: resumed });
    await waitForRevision(phoneToken, resumed.revision);
    const start = (await activityPushes(phoneToken)).find((p) => p.event === "activity-start");
    expect(start.status).toBe(410);
    expect((await call("PUT", "/v1/tokens/activity", { token: phoneToken, body: { activityID: start.sessionID, token: activityToken } })).status).toBe(409);
    expect((await pushes(phoneToken)).filter((p) => p.event === "reminder")).toHaveLength(1);
  });

  it("starts one new session with one card when the player's token has died over a long pause", async () => {
    const { mac, pairingID, phoneToken, sessionID } = await playingSetup();
    await call("PUT", "/v1/tokens/alert", { token: phoneToken, body: { token: alertToken } });
    await call("PUT", "/v1/tokens/activity-start", { token: phoneToken, body: { token: startToken } });
    const paused = playback({ state: "paused", isPlaying: false, track: lowSun });
    mac.send({ type: "state", message: paused });
    await waitForRevision(phoneToken, paused.revision);
    await pauseFor(pairingID, 9);
    // Hours of Apple Music on the phone: iOS has dropped the player, and APNs calls its token dead.
    await editStorage(pairingID, async (storage) => storage.put("mockDeadTokens", ["cd".repeat(32)]));
    const before = (await pushes(phoneToken)).length;
    // The Mac plays again, and a moment later sends the song again with its artwork.
    const resumed = playback({ track: { ...lowSun, artworkID: undefined } });
    mac.send({ type: "state", message: resumed });
    await waitForRevision(phoneToken, resumed.revision);
    const withArtwork = playback({ track: lowSun });
    mac.send({ type: "state", message: withArtwork });
    await waitForRevision(phoneToken, withArtwork.revision);

    const sent = (await pushes(phoneToken)).slice(before);
    expect(sent.filter((p) => p.event === "activity-start")).toHaveLength(1);
    const started = sent.filter((p) => p.event === "start");
    expect(started).toHaveLength(1);
    expect(started[0].sessionID).not.toBe(sessionID);
    expect((await session(phoneToken)).sessionID).toBe(started[0].sessionID);
    expect(sent.filter((p) => p.event === "reminder")).toHaveLength(0);
  });

  it("stops updating a card the phone has ended", async () => {
    const { mac, phoneToken, activityID } = await cardStarted();
    await call("PUT", "/v1/tokens/activity", { token: phoneToken, body: { activityID, token: activityToken } });
    expect((await call("DELETE", `/v1/tokens/activity/${activityID}`, { token: phoneToken })).status).toBe(204);
    const before = (await activityPushes(phoneToken)).length;
    const next = playback({ track: smallHours });
    mac.send({ type: "state", message: next });
    await waitForRevision(phoneToken, next.revision);
    expect(await activityPushes(phoneToken)).toHaveLength(before);
  });
});
