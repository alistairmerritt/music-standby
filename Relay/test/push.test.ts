import { describe, expect, it } from "vitest";
import { APNsPushSender, makePush, tokenIsDead } from "../src/push";
import type { NowPlayingAttributes } from "../src/protocol";

const attributes: NowPlayingAttributes = {
  id: "9d0f3c2a-6b1e-4f7d-8a5c-2e4b6d8f0a1c",
  macName: "Studio Mac",
  revision: 1794207600001,
  isPlaying: true,
  elapsedTime: 251.5,
  timestamp: "2026-11-09T07:00:00.250Z",
  track: { id: "pid:542CEB17C137B39E", title: "Losing My Edge", artist: "LCD Soundsystem", album: "LCD Soundsystem", duration: 473.114, artworkID: "" },
  canGoNext: true,
  canGoPrevious: true,
};

async function testKey() {
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const pkcs8 = new Uint8Array((await crypto.subtle.exportKey("pkcs8", pair.privateKey)) as ArrayBuffer);
  const pem = `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...pkcs8))}\n-----END PRIVATE KEY-----`;
  return { pem, publicKey: pair.publicKey };
}

function b64urlDecode(s: string): Uint8Array {
  const b64 = s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4);
  return Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
}

describe("APNs push payloads", () => {
  it("builds start and update with full attributes and end with only the id", () => {
    const start = makePush("start", "aa", attributes, 1794207600999);
    expect(start.payload).toEqual({ aps: { event: "start", timestamp: 1794207600, attributes } });
    const end = makePush("end", "aa", attributes);
    expect(end.payload.aps.attributes).toEqual({ id: attributes.id });
  });

  it("recognises tokens APNs will never accept again", () => {
    expect(tokenIsDead({ status: 410, reason: "Unregistered" })).toBe(true);
    expect(tokenIsDead({ status: 400, reason: "BadDeviceToken" })).toBe(true);
    expect(tokenIsDead({ status: 400, reason: "BadTopic" })).toBe(false);
    expect(tokenIsDead({ status: 429, reason: "TooManyRequests" })).toBe(false);
    expect(tokenIsDead({ status: 200 })).toBe(false);
  });
});

describe("APNsPushSender", () => {
  it("signs an ES256 provider token that verifies with the key's public half", async () => {
    const { pem, publicKey } = await testKey();
    const sender = new APNsPushSender({ keyP8: pem, keyID: "ABC123DEFG", teamID: "TEAM123456", topic: "t", environment: "development" });
    const jwt = await sender.providerToken(1794207600000);
    const [header, claims, signature] = jwt.split(".");
    expect(JSON.parse(new TextDecoder().decode(b64urlDecode(header)))).toEqual({ alg: "ES256", kid: "ABC123DEFG" });
    expect(JSON.parse(new TextDecoder().decode(b64urlDecode(claims)))).toEqual({ iss: "TEAM123456", iat: 1794207600 });
    const valid = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, publicKey, b64urlDecode(signature), new TextEncoder().encode(`${header}.${claims}`));
    expect(valid).toBe(true);
    // Reused inside 30 minutes, renewed after.
    expect(await sender.providerToken(1794207600000 + 29 * 60_000)).toBe(jwt);
    expect(await sender.providerToken(1794207600000 + 31 * 60_000)).not.toBe(jwt);
  });

  it("sends Apple's nowplaying headers and body to the token's device path", async () => {
    const { pem } = await testKey();
    const seen: Request[] = [];
    const fetcher = (async (input: RequestInfo | URL, init?: RequestInit) => {
      seen.push(new Request(input, init));
      return new Response(null, { status: 200 });
    }) as typeof fetch;
    const sender = new APNsPushSender(
      { keyP8: pem, keyID: "K", teamID: "T", topic: "com.alistairmerritt.MusicStandBy.push-type.nowplaying", environment: "development" },
      fetcher,
    );
    const push = makePush("update", "0123abcd", attributes);
    expect(await sender.send(push)).toEqual({ status: 200 });
    const request = seen[0];
    expect(request.url).toBe("https://api.sandbox.push.apple.com/3/device/0123abcd");
    expect(request.method).toBe("POST");
    expect(request.headers.get("apns-push-type")).toBe("nowplaying");
    expect(request.headers.get("apns-topic")).toBe("com.alistairmerritt.MusicStandBy.push-type.nowplaying");
    expect(request.headers.get("apns-priority")).toBe("10");
    expect(request.headers.get("authorization")).toMatch(/^bearer [\w-]+\.[\w-]+\.[\w-]+$/);
    expect(Number(request.headers.get("apns-expiration"))).toBeGreaterThan(Date.now() / 1000);
    expect(await request.json()).toEqual(push.payload);
  });

  it("reports APNs' reason on failure and uses the production host when told", async () => {
    const { pem } = await testKey();
    const fetcher = (async () => new Response(JSON.stringify({ reason: "BadDeviceToken" }), { status: 400 })) as typeof fetch;
    const sender = new APNsPushSender({ keyP8: pem, keyID: "K", teamID: "T", topic: "t", environment: "production" }, fetcher);
    expect(sender.host).toBe("https://api.push.apple.com");
    expect(await sender.send(makePush("end", "ff", attributes))).toEqual({ status: 400, reason: "BadDeviceToken" });
  });
});
