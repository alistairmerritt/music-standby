import { runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import {
  MacSocket,
  call,
  createMac,
  directoryStub,
  editStorage,
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
    const state = playback({ track: { id: "pid:A", title: "Song", artist: "Artist", album: "Album", duration: 200, artworkID: "a".repeat(64) } });
    mac.send({ type: "state", message: state });
    const s = await waitForRevision(phoneToken, state.revision);
    expect(s.sessionID).toMatch(/^[0-9a-f-]{36}$/);
    expect(s.macConnected).toBe(true);
    expect(s.playback).toEqual(state);
    expect(s.attributes).toMatchObject({
      id: s.sessionID,
      macName: "Studio Mac",
      revision: state.revision,
      isPlaying: true,
      elapsedTime: 12.5,
      timestamp: state.capturedAt,
      track: { id: "pid:A", title: "Song", artworkID: "a".repeat(64) },
      canGoNext: true,
    });
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

  it("refuses a command with no session, or without a session id", async () => {
    const { phoneToken } = await pairedSetup();
    const a = commandBody(crypto.randomUUID());
    const noSession = await call("POST", "/v1/commands", { token: phoneToken, body: a.body, headers: { "Idempotency-Key": a.id } });
    expect((await noSession.json<any>()).error.code).toBe("no_session");
    const b = commandBody(undefined);
    const missing = await call("POST", "/v1/commands", { token: phoneToken, body: b.body, headers: { "Idempotency-Key": b.id } });
    expect(missing.status).toBe(400);
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
    await pauseFor(pairingID, 31);
    const resumed = playback();
    mac.send({ type: "state", message: resumed });
    await waitForRevision(phoneToken, resumed.revision);
    const sent = await reminders(phoneToken);
    expect(sent).toHaveLength(1);
    expect(sent[0].payload).toEqual({
      aps: { alert: { title: "Music playing on Studio Mac", body: "Tap to show on your Lock Screen." }, "thread-id": "mac-playing" },
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
    await pauseFor(pairingID, 5);
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
