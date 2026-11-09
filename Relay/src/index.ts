// Music StandBy relay: one Worker, one Pairing Durable Object per Mac, and a
// Directory Durable Object for pairing codes and rate limits.
// Contract: docs/relay/API-v1.md.

import { bearer, newID, newToken, parseToken, sha256Hex } from "./crypto";
import { directory, pairing, type Env } from "./env";
import { HttpError, clientIP, errorResponse, json, readJSON } from "./http";
import { PROTOCOL_VERSION, isDevice, type DeviceIdentity } from "./protocol";
import { CODE_TTL_MS } from "./directory";
import { APNsPushSender } from "./push";

export { Directory } from "./directory";
export { Pairing } from "./pairing";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      return await route(request, env);
    } catch (e) {
      if (e instanceof HttpError) return errorResponse(e);
      console.error(`relay: unhandled ${(e as Error).message}`);
      return errorResponse(new HttpError(500, "internal"));
    }
  },
} satisfies ExportedHandler<Env>;

async function route(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  const path = url.pathname;
  const method = request.method;

  if (method === "GET" && path === "/v1/health") return json(200, { ok: true, protocolVersion: PROTOCOL_VERSION });
  if (method === "POST" && path === "/v1/pairings") return createPairing(request, env);
  if (method === "POST" && path === "/v1/pairing/claim") return claim(request, env);
  if (method === "GET" && path === "/v1/dev/apns-probe" && env.DEV_ENDPOINTS === "1") return apnsProbe();

  // Artwork capability URLs carry the pairing in the path, not a credential.
  const artwork = /^\/v1\/artwork\/([0-9a-f]{32})\/[0-9a-f]{64}$/.exec(path);
  if (artwork && method === "GET") return pairing(env, artwork[1]).fetch(request);

  // Everything else is routed by the credential; the Pairing object checks it.
  const token = parseToken(bearer(request));
  if (!token) throw new HttpError(401, "unauthorized");
  return pairing(env, token.id).fetch(request);
}

async function createPairing(request: Request, env: Env): Promise<Response> {
  const wait = await directory(env).hit(`create:${clientIP(request)}`, 5, 3600);
  if (wait) throw new HttpError(429, "rate_limited", "too many new pairings from this address", wait);
  const body = await readJSON<{ device?: DeviceIdentity }>(request);
  if (!isDevice(body?.device) || body.device.kind !== "mac") throw new HttpError(400, "invalid_request", "device must be a mac DeviceIdentity");
  const pairingID = newID();
  const macToken = newToken("mac", pairingID);
  await pairing(env, pairingID).create(pairingID, body.device, await sha256Hex(macToken));
  return json(201, { pairingID, macToken });
}

async function claim(request: Request, env: Env): Promise<Response> {
  const wait = await directory(env).hit(`claim:${clientIP(request)}`, 10, 60);
  if (wait) throw new HttpError(429, "rate_limited", "too many pairing attempts", wait);
  const body = await readJSON<{ code?: string; phone?: DeviceIdentity }>(request);
  if (typeof body?.code !== "string" || !/^\d{6}$/.test(body.code) || !isDevice(body.phone)) {
    throw new HttpError(400, "invalid_request", "a six-digit code and a phone DeviceIdentity are required");
  }
  const pairingID = await directory(env).consumeCode(body.code);
  if (!pairingID) throw new HttpError(404, "pairing_code_invalid");
  const claimID = newID();
  const claimSecret = newToken("claim", pairingID);
  const expiresAt = Date.now() + CODE_TTL_MS;
  const mac = await pairing(env, pairingID).addClaim(claimID, body.phone, await sha256Hex(claimSecret), expiresAt);
  if (!mac) throw new HttpError(404, "pairing_code_invalid");
  return json(202, { claimID, claimSecret, expiresAt: new Date(expiresAt).toISOString(), mac });
}

/**
 * Relay design §8: does this runtime reach APNs over HTTP/2? Sends a request
 * with a deliberately invalid provider token. Any APNs JSON answer
 * (InvalidProviderToken, BadDeviceToken…) means HTTP/2 was negotiated and APNs
 * parsed the request; a transport error means it wasn't. Needs no credentials.
 */
async function apnsProbe(): Promise<Response> {
  const sender = new APNsPushSender({ keyP8: "", keyID: "PROBE", teamID: "PROBE", topic: "com.alistairmerritt.MusicStandBy.push-type.nowplaying", environment: "development" });
  const started = Date.now();
  try {
    const response = await fetch(`${sender.host}/3/device/${"0".repeat(64)}`, {
      method: "POST",
      headers: { ...sender.headers({ event: "update", token: "", sessionID: "probe", payload: { aps: { event: "update", timestamp: 0, attributes: { id: "probe" } } } }, "probe.invalid.jwt") },
      body: JSON.stringify({ aps: { event: "update", timestamp: Math.floor(Date.now() / 1000), attributes: { id: "probe" } } }),
    });
    const text = await response.text();
    let apnsReason: string | undefined;
    try {
      apnsReason = (JSON.parse(text) as { reason?: string }).reason;
    } catch {
      // not JSON: not APNs speaking
    }
    return json(200, {
      reachedAPNs: apnsReason !== undefined,
      status: response.status,
      apnsReason,
      apnsID: response.headers.get("apns-id"),
      body: text.slice(0, 300),
      ms: Date.now() - started,
    });
  } catch (e) {
    return json(200, { reachedAPNs: false, error: (e as Error).message, ms: Date.now() - started });
  }
}
