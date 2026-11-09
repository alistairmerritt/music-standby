#!/usr/bin/env node
// A command-line iPhone for the relay: the same HTTPS calls the iOS app and its
// Now Playing extension make (docs/relay/API-v1.md). No dependencies.
//
//   node tools/mock-phone.mjs pair CODE          claim a code; waits for the Mac to allow it
//   node tools/mock-phone.mjs session            GET /v1/session
//   node tools/mock-phone.mjs watch [SECONDS]    print each change the relay sees
//   node tools/mock-phone.mjs cmd KIND [--twice] [--session ID]
//                                                play | pause | next | previous. --twice sends
//                                                the same command id again; --session overrides
//                                                the session id (to test session_mismatch)
//   node tools/mock-phone.mjs tokens             register made-up push tokens (pushes stay mocked)
//   node tools/mock-phone.mjs pushes             what the relay would have pushed
//   node tools/mock-phone.mjs artwork [FILE]     fetch the current artwork through its signed URL
//   node tools/mock-phone.mjs unpair
//
// Options: --relay URL (default http://127.0.0.1:8787), --state FILE (default in $TMPDIR).

import { createHash, randomBytes, randomUUID } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const args = process.argv.slice(2);
const option = (name) => {
  const i = args.indexOf(name);
  if (i < 0) return undefined;
  const value = args[i + 1];
  args.splice(i, 2);
  return value;
};
const flag = (name) => {
  const i = args.indexOf(name);
  if (i >= 0) args.splice(i, 1);
  return i >= 0;
};

const relay = (option("--relay") ?? "http://127.0.0.1:8787").replace(/\/$/, "");
const stateFile = option("--state") ?? join(tmpdir(), "mock-phone.json");
const twice = flag("--twice");
const sessionOverride = option("--session");
const [command, ...rest] = args;

const phone = { id: "MOCK-PHONE-0001", name: "Mock iPhone", kind: "iphone", appVersion: "mock", osVersion: "27.2" };

const load = () => {
  try {
    return JSON.parse(readFileSync(stateFile, "utf8"));
  } catch {
    return {};
  }
};
const saved = load();

async function api(method, path, { token = saved.phoneToken, body, headers = {} } = {}) {
  const started = performance.now();
  const response = await fetch(`${relay}${path}`, {
    method,
    headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(body ? { "Content-Type": "application/json" } : {}), ...headers },
    body: body ? JSON.stringify(body) : undefined,
  });
  const ms = Math.round(performance.now() - started);
  const text = await response.text();
  let json;
  try {
    json = text ? JSON.parse(text) : undefined;
  } catch {
    json = undefined;
  }
  return { status: response.status, json, text, ms };
}

function fail(message, result) {
  console.error(`✗ ${message}${result ? ` (HTTP ${result.status} ${result.text})` : ""}`);
  process.exit(1);
}

function describe(s) {
  if (!s.sessionID) return `no session · Mac ${s.macConnected ? "connected" : "offline"} · playback ${s.playback?.state ?? "none"}`;
  const a = s.attributes;
  const t = a.track ? `${a.track.title} — ${a.track.artist}` : "(no track)";
  return `${a.isPlaying ? "▶" : "❚❚"} ${t} · r${a.revision} · session ${s.sessionID.slice(0, 8)} · art ${a.track?.artworkURL ? "yes" : "no"}`;
}

switch (command) {
  case "pair": {
    const code = rest[0];
    if (!/^\d{6}$/.test(code ?? "")) fail("usage: pair CODE");
    const claim = await api("POST", "/v1/pairing/claim", { token: null, body: { code, phone } });
    if (claim.status !== 202) fail("claim refused", claim);
    console.log(`waiting for "${claim.json.mac.name}" to allow this phone…`);
    for (let i = 0; i < 300; i++) {
      const poll = await api("GET", `/v1/pairing/claim/${claim.json.claimID}`, { token: claim.json.claimSecret });
      if (poll.status !== 200) fail("claim ended", poll);
      if (poll.json.status === "approved") {
        writeFileSync(stateFile, JSON.stringify({ relay, phoneToken: poll.json.phoneToken, pairingID: poll.json.pairingID, mac: poll.json.mac }, null, 2), { mode: 0o600 });
        console.log(`✓ paired with "${poll.json.mac.name}"; credential in ${stateFile}`);
        process.exit(0);
      }
      if (poll.json.status === "denied") fail("the Mac refused");
      await new Promise((r) => setTimeout(r, 1000));
    }
    fail("timed out waiting for the Mac");
  }

  case "session": {
    const s = await api("GET", "/v1/session");
    if (s.status !== 200) fail("session", s);
    console.log(describe(s.json));
    console.log(JSON.stringify(s.json, null, 2));
    break;
  }

  case "watch": {
    const seconds = Number(rest[0] ?? 30);
    const until = Date.now() + seconds * 1000;
    let last = "";
    while (Date.now() < until) {
      const s = await api("GET", "/v1/session");
      if (s.status !== 200) fail("session", s);
      const line = describe(s.json);
      if (line !== last) console.log(`${new Date().toISOString().slice(11, 23)} ${line}`);
      last = line;
      await new Promise((r) => setTimeout(r, 500));
    }
    break;
  }

  case "cmd": {
    const kind = rest[0];
    if (!["play", "pause", "next", "previous"].includes(kind)) fail("usage: cmd play|pause|next|previous");
    const before = await api("GET", "/v1/session");
    const sessionID = sessionOverride ?? before.json?.sessionID;
    const id = randomUUID().toUpperCase();
    const body = { command: { id, kind, issuedAt: new Date().toISOString() }, ...(sessionID ? { sessionID } : {}) };
    const send = () => api("POST", "/v1/commands", { body, headers: { "Idempotency-Key": id } });
    const first = await send();
    console.log(`${kind}: HTTP ${first.status} in ${first.ms} ms ${first.text}`);
    if (twice) {
      const second = await send();
      console.log(`${kind} again, same id: HTTP ${second.status} in ${second.ms} ms ${second.text}`);
    }
    process.exit(first.status === 200 && first.json?.ack?.accepted ? 0 : 2);
  }

  case "tokens": {
    const s = await api("GET", "/v1/session");
    const start = await api("PUT", "/v1/tokens/start", { body: { token: randomBytes(32).toString("hex") } });
    console.log(`push-to-start token: HTTP ${start.status}`);
    if (s.json?.sessionID) {
      const t = await api("PUT", "/v1/tokens/session", { body: { sessionID: s.json.sessionID, token: randomBytes(32).toString("hex") } });
      console.log(`session token for ${s.json.sessionID.slice(0, 8)}: HTTP ${t.status}`);
    }
    break;
  }

  case "pushes": {
    const p = await api("GET", "/v1/dev/pushes");
    if (p.status !== 200) fail("pushes", p);
    for (const push of p.json.pushes) {
      const a = push.payload.aps.attributes;
      console.log(`${push.at} ${push.event.padEnd(6)} session ${push.sessionID.slice(0, 8)} ${a.track ? `${a.track.title} ${a.isPlaying ? "▶" : "❚❚"}` : ""}`);
    }
    break;
  }

  case "artwork": {
    const s = await api("GET", "/v1/session");
    const url = s.json?.attributes?.track?.artworkURL;
    if (!url) fail("the current track has no artwork URL");
    // Fetched like the extension will: the signed URL alone, no credential.
    const response = await fetch(url);
    const bytes = Buffer.from(await response.arrayBuffer());
    if (!response.ok) fail(`artwork HTTP ${response.status}`);
    const out = rest[0] ?? join(tmpdir(), "mock-phone-artwork.jpg");
    writeFileSync(out, bytes);
    console.log(`✓ ${bytes.length} bytes ${response.headers.get("content-type")} sha256 ${createHash("sha256").update(bytes).digest("hex").slice(0, 16)}… → ${out}`);
    break;
  }

  case "unpair": {
    const r = await api("DELETE", "/v1/pairing");
    console.log(`unpair: HTTP ${r.status}`);
    break;
  }

  default:
    console.log(readFileSync(new URL(import.meta.url), "utf8").split("\n").slice(1, 18).map((l) => l.replace(/^\/\/ ?/, "")).join("\n"));
    process.exit(command ? 2 : 0);
}
