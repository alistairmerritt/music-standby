#!/usr/bin/env node
// End-to-end test on one Mac: the real Mac companion (msbctl) ↔ a local relay
// (wrangler dev) ↔ a simulated iPhone (this script, over HTTPS-shaped calls).
//
//   node tools/e2e-local.mjs --msbctl PATH [--playback] [--relay URL]
//
// --relay runs the same checks against a deployed relay instead of starting
// one, skips the relay-restart step, and unpairs the Mac it registered when it
// finishes, so it leaves nothing behind on the relay.
//
// Without --playback nothing changes Music: only reads, pairing, auth,
// sessions, artwork and connection loss. With --playback it also sends
// next, pause and play to the real Music.app, which must already be playing,
// and leaves it paused. It never changes the volume and never launches Music.

import { spawn } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { randomUUID } from "node:crypto";

const args = process.argv.slice(2);
const opt = (name) => (args.includes(name) ? args[args.indexOf(name) + 1] : undefined);
const msbctl = opt("--msbctl");
const playback = args.includes("--playback");
const port = Number(opt("--port") ?? 8791);
const remote = opt("--relay")?.replace(/\/+$/, "");
if (!msbctl) {
  console.error("usage: node tools/e2e-local.mjs --msbctl PATH [--playback] [--port N | --relay URL]");
  process.exit(2);
}

const relayDir = join(dirname(fileURLToPath(import.meta.url)), "..");
const work = mkdtempSync(join(tmpdir(), "msb-e2e-"));
const base = remote ?? `http://127.0.0.1:${port}`;
const results = [];
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let relay, mac, macLog = "";

function check(name, ok, detail = "") {
  results.push({ name, ok });
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}${detail ? `  — ${detail}` : ""}`);
}

async function until(fn, ms = 8000, step = 150) {
  const deadline = Date.now() + ms;
  for (;;) {
    const v = await fn().catch(() => undefined);
    if (v) return v;
    if (Date.now() > deadline) return undefined;
    await sleep(step);
  }
}

async function api(method, path, { token, body, headers = {} } = {}) {
  const started = performance.now();
  const r = await fetch(`${base}${path}`, {
    method,
    headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(body ? { "Content-Type": "application/json" } : {}), ...headers },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await r.text();
  let json;
  try { json = JSON.parse(text); } catch { json = undefined; }
  return { status: r.status, json, text, ms: Math.round(performance.now() - started) };
}

function startRelay() {
  if (remote) return until(async () => (await fetch(`${base}/v1/health`)).ok, 15000, 500);
  relay = spawn("npx", ["wrangler", "dev", "--ip", "127.0.0.1", "--port", String(port), "--persist-to", join(work, "relay-state"), "--var", "DEV_ENDPOINTS:1"], {
    cwd: relayDir, env: { ...process.env, WRANGLER_SEND_METRICS: "false" }, stdio: ["ignore", "pipe", "pipe"],
  });
  relay.stdout.resume();
  relay.stderr.resume();
  return until(async () => (await fetch(`${base}/v1/health`)).ok, 30000, 300);
}

function stopRelay() {
  return new Promise((resolve) => {
    if (!relay || relay.exitCode !== null) return resolve();
    relay.once("exit", resolve);
    relay.kill("SIGINT");
  });
}

function startMac(extra = []) {
  mac = spawn(msbctl, ["watch", "900", "--relay", base, "--credentials", join(work, "mac.json"), ...extra], { stdio: ["pipe", "pipe", "pipe"] });
  mac.stdout.on("data", (d) => (macLog += d.toString()));
  mac.stderr.on("data", (d) => (macLog += d.toString()));
}

const phone = { id: "E2E-PHONE", name: "E2E iPhone", kind: "iphone" };
let phoneToken, sessionID;
const session = async () => (await api("GET", "/v1/session", { token: phoneToken })).json;
const command = (kind, { id = randomUUID().toUpperCase(), session = sessionID } = {}) =>
  api("POST", "/v1/commands", { token: phoneToken, headers: { "Idempotency-Key": id }, body: { command: { id, kind, issuedAt: new Date().toISOString() }, sessionID: session } });

try {
  // 1. Relay and Mac
  check(remote ? `deployed relay answers at ${base}` : "relay starts under wrangler dev", !!(await startRelay()));
  startMac(["--pair"]);
  const code = await until(async () => macLog.match(/PAIRING CODE (\d{6})/)?.[1], 15000);
  check("Mac registers, connects and gets a pairing code", !!code, code ? `code ${code}` : macLog.slice(-300));

  // 2. Pairing, with approval on the Mac
  const claim = await api("POST", "/v1/pairing/claim", { body: { code, phone } });
  check("phone claims the code", claim.status === 202, `HTTP ${claim.status}`);
  const pending = await api("GET", `/v1/pairing/claim/${claim.json.claimID}`, { token: claim.json.claimSecret });
  check("nothing is granted before the Mac approves", pending.json?.status === "pending");
  check("the Mac is asked", !!(await until(async () => macLog.includes("E2E iPhone asks to pair"))));
  mac.stdin.write("approve\n");
  const approved = await until(async () => {
    const r = await api("GET", `/v1/pairing/claim/${claim.json.claimID}`, { token: claim.json.claimSecret });
    return r.json?.status === "approved" ? r.json : undefined;
  });
  phoneToken = approved?.phoneToken;
  check("phone receives its credential after approval", !!phoneToken);
  const again = await api("GET", `/v1/pairing/claim/${claim.json.claimID}`, { token: claim.json.claimSecret });
  check("the credential is handed over only once", again.status === 410);
  const reuse = await api("POST", "/v1/pairing/claim", { body: { code, phone } });
  check("a used pairing code is refused", reuse.status === 404 && reuse.json?.error?.code === "pairing_code_invalid");

  // 3. Authentication
  const forged = await api("GET", "/v1/session", { token: `msb1.phone.${approved.pairingID}.${"A".repeat(43)}` });
  check("a forged phone credential is refused", forged.status === 401);
  const macAsPhone = await api("POST", "/v1/commands", { token: "garbage", body: {} });
  check("a malformed credential is refused", macAsPhone.status === 401);

  // 4. Playback state delivery
  const first = await until(async () => {
    const s = await session();
    return s?.macConnected && s.playback ? s : undefined;
  });
  check("phone sees the Mac connected and its real playback state", !!first, first ? `Music ${first.playback.state}${first.playback.track ? `: ${first.playback.track.title}` : ""}` : "");
  sessionID = first?.sessionID;

  // 5. Commands and sessions
  const stale = await command("next", { session: "00000000-0000-4000-8000-000000000000" });
  check("a command for another session is refused", stale.status === 409 || (!sessionID && stale.status === 409));

  if (playback) {
    if (!sessionID) {
      check("--playback needs Music playing", false, "no session; start something in Music first");
    } else {
      const before = first.playback.track?.id;
      const next = await command("next");
      check("Next from the phone is acknowledged", next.status === 200 && next.json?.ack?.accepted, `${next.ms} ms`);
      const changed = await until(async () => {
        const s = await session();
        return s?.playback?.track?.id && s.playback.track.id !== before ? s : undefined;
      });
      check("Next changes the real song on the Mac", !!changed, changed ? `${first.playback.track?.title} → ${changed.playback.track.title}` : "");

      const pause = await command("pause");
      const paused = await until(async () => ((await session())?.playback?.state === "paused" ? true : undefined));
      check("Pause from the phone pauses Music", pause.json?.ack?.accepted && !!paused, `${pause.ms} ms`);
      const play = await command("play");
      const playing = await until(async () => ((await session())?.playback?.state === "playing" ? true : undefined));
      check("Play from the phone resumes Music", play.json?.ack?.accepted && !!playing, `${play.ms} ms`);

      const nextsBefore = (macLog.match(/command next →/g) ?? []).length;
      const id = randomUUID().toUpperCase();
      const a = await command("next", { id });
      const b = await command("next", { id });
      await sleep(1500);
      const nextsAfter = (macLog.match(/command next →/g) ?? []).length;
      check("a repeated command id acts once", a.text === b.text && nextsAfter - nextsBefore === 1, `${nextsAfter - nextsBefore} next(s) on the Mac`);
      sessionID = (await session())?.sessionID ?? sessionID;
    }
  } else {
    console.log("skip  playback commands (run with --playback while Music is playing)");
  }

  // 6. Artwork
  const art = (await session())?.attributes?.track?.artworkURL;
  if (art) {
    const r = await until(async () => {
      const res = await fetch(art);
      return res.ok ? res : undefined;
    });
    check("artwork is served through its signed URL without a credential", r?.headers.get("content-type") === "image/jpeg");
    const unsigned = await fetch(art.split("?")[0]);
    check("artwork without signature or credential is refused", unsigned.status === 401);
  } else {
    console.log("skip  artwork (the current track has none, or nothing is playing)");
  }

  // 7. Mac disconnection and reconnection
  mac.kill("SIGKILL");
  const offline = await until(async () => ((await session())?.macConnected === false ? true : undefined));
  check("the relay notices the Mac has gone", !!offline);
  if (sessionID) {
    const r = await command("pause");
    check("a command while the Mac is away answers 504", r.status === 504 && r.json?.error?.code === "mac_unreachable");
  }
  macLog = "";
  startMac();
  const back = await until(async () => ((await session())?.macConnected ? await session() : undefined), 15000);
  check("the Mac reconnects with its saved credential", !!back);
  if (sessionID) check("the session survives a companion restart", back?.sessionID === sessionID, `${sessionID?.slice(0, 8)} → ${back?.sessionID?.slice(0, 8)}`);

  // 8. Relay restart (local only: a deployed relay isn't ours to stop)
  if (remote) {
    console.log("skip  relay restart (deployed relay)");
  } else {
    await stopRelay();
    check("relay stopped", !(await fetch(`${base}/v1/health`).then(() => true).catch(() => false)));
    await startRelay();
    const resumed = await until(async () => ((await session())?.macConnected ? true : undefined), 40000, 500);
    check("the Mac reconnects after the relay restarts", !!resumed);
  }

  // 9. Session termination and revocation
  const end = sessionID ? await api("POST", "/v1/session/end", { token: phoneToken, body: { sessionID } }) : undefined;
  if (end) check("the phone can end the session", end.status === 204 && !(await session())?.sessionID);
  const unpair = await api("DELETE", "/v1/pairing", { token: phoneToken });
  check("unpairing succeeds", unpair.status === 204);
  check("the Mac hears it was revoked", !!(await until(async () => macLog.includes("pairing revoked"))));
  check("the phone's credential is dead afterwards", (await api("GET", "/v1/session", { token: phoneToken })).status === 401);

  // 10. Recovery: the Mac registers afresh and can pair again
  const reregistered = await until(async () => /re-registered as pairing[\s\S]*relay welcome/.test(macLog), 15000);
  check("the Mac re-registers and reconnects after being unpaired", !!reregistered);
  macLog = "";
  mac.stdin.write("code\n");
  const code2 = await until(async () => macLog.match(/PAIRING CODE (\d{6})/)?.[1], 10000);
  const claim2 = code2 ? await api("POST", "/v1/pairing/claim", { body: { code: code2, phone } }) : undefined;
  await until(async () => macLog.includes("E2E iPhone asks to pair"));
  mac.stdin.write("approve\n");
  const again2 = claim2 && (await until(async () => {
    const r = await api("GET", `/v1/pairing/claim/${claim2.json.claimID}`, { token: claim2.json.claimSecret });
    return r.json?.status === "approved" ? r.json : undefined;
  }));
  const fresh = again2 ? await api("GET", "/v1/session", { token: again2.phoneToken }) : undefined;
  check("a phone can pair with the Mac again", fresh?.status === 200 && fresh.json.macConnected === true);
} catch (e) {
  check("harness ran to the end", false, e.message);
} finally {
  if (playback && phoneToken) {
    // Leave Music paused, whatever happened above.
    spawn(msbctl, ["control", "pause"], { stdio: "ignore" });
    await sleep(1500);
  }
  if (mac && mac.exitCode === null) {
    await new Promise((resolve) => { mac.once("exit", resolve); mac.kill("SIGINT"); setTimeout(resolve, 3000); });
  }
  if (remote) {
    // Unpair whatever pairing the Mac holds now, so the run leaves nothing behind.
    try {
      const { macToken } = JSON.parse(readFileSync(join(work, "mac.json"), "utf8"));
      const r = await api("DELETE", "/v1/pairing", { token: macToken });
      console.log(`cleanup  unpaired the test Mac on the relay (HTTP ${r.status})`);
    } catch (e) {
      console.log(`cleanup  nothing to unpair (${e.message})`);
    }
  }
  await stopRelay();
  rmSync(work, { recursive: true, force: true });
  const failed = results.filter((r) => !r.ok).length;
  console.log(`\n${results.length - failed}/${results.length} passed`);
  process.exit(failed ? 1 : 0);
}
