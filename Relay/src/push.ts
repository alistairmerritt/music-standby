// Remote Now Playing pushes, per Apple's "Publishing remote media sessions":
// push type `nowplaying`, topic `<bundle id>.push-type.nowplaying`, `start` to
// the push-to-start token, `update` and `end` to the session's own token.
//
// MockPushSender records pushes; APNsPushSender sends them. APNs answers only
// over HTTP/2, which a deployed Worker has and local workerd doesn't.

import { base64url } from "./crypto";
import type { NowPlayingAttributes } from "./protocol";

export type PushEvent = "start" | "update" | "end";

export interface Push {
  event: PushEvent;
  token: string;
  /** The full APNs body: {"aps": {...}}. */
  payload: { aps: { event: PushEvent; timestamp: number; attributes: NowPlayingAttributes | { id: string } } };
  sessionID: string;
}

export interface PushResult {
  status: number;
  /** APNs `reason`, e.g. BadDeviceToken. */
  reason?: string;
}

export interface PushSender {
  send(push: Push): Promise<PushResult>;
}

export function makePush(event: PushEvent, token: string, attributes: NowPlayingAttributes, now = Date.now()): Push {
  return {
    event,
    token,
    sessionID: attributes.id,
    payload: {
      aps: {
        event,
        timestamp: Math.floor(now / 1000),
        attributes: event === "end" ? { id: attributes.id } : attributes,
      },
    },
  };
}

/** True when APNs says the token will never work again. */
export function tokenIsDead(result: PushResult): boolean {
  return result.status === 410 || (result.status === 400 && (result.reason === "BadDeviceToken" || result.reason === "DeviceTokenNotForTopic"));
}

/** Records pushes instead of sending them. */
export class MockPushSender implements PushSender {
  constructor(private readonly record: (push: Push) => Promise<void>) {}
  async send(push: Push): Promise<PushResult> {
    await this.record(push);
    return { status: 200 };
  }
}

export interface APNsConfig {
  keyP8: string;
  keyID: string;
  teamID: string;
  topic: string;
  environment: "development" | "production";
}

/** A signed provider token, with what it was signed for and when. */
export interface ProviderToken {
  token: string;
  issuedAt: number;
  keyID: string;
  teamID: string;
}

/**
 * Keeps the provider token across instances. A Durable Object is evicted
 * between pushes; without this, each wake would sign a new token, and APNs
 * answers 429 TooManyProviderTokenUpdates to more than one every 20 minutes.
 */
export interface ProviderTokenStore {
  get(): Promise<ProviderToken | undefined>;
  put(token: ProviderToken | undefined): Promise<void>;
}

/** Apple: refresh no more than once every 20 minutes, and within 60. */
const PROVIDER_TOKEN_REUSE_MS = 30 * 60 * 1000;

export class APNsPushSender implements PushSender {
  private jwt?: ProviderToken;

  constructor(
    private readonly config: APNsConfig,
    // Called through a wrapper: Workers throw "Illegal invocation" when the
    // global fetch is called as a method of another object.
    private readonly fetcher: typeof fetch = (input, init) => fetch(input, init),
    private readonly store?: ProviderTokenStore,
  ) {}

  get host(): string {
    return this.config.environment === "production" ? "https://api.push.apple.com" : "https://api.sandbox.push.apple.com";
  }

  async send(push: Push): Promise<PushResult> {
    const response = await this.fetcher(`${this.host}/3/device/${push.token}`, {
      method: "POST",
      headers: this.headers(push, await this.providerToken()),
      body: JSON.stringify(push.payload),
    });
    if (response.ok) return { status: response.status };
    let reason: string | undefined;
    try {
      reason = ((await response.json()) as { reason?: string }).reason;
    } catch {
      // APNs always sends JSON on failure; anything else is a transport problem.
    }
    if (response.status === 403 && reason === "ExpiredProviderToken") {
      this.jwt = undefined;
      await this.store?.put(undefined);
    }
    return { status: response.status, reason };
  }

  headers(push: Push, jwt: string): Record<string, string> {
    return {
      authorization: `bearer ${jwt}`,
      "apns-push-type": "nowplaying",
      "apns-topic": this.config.topic,
      "apns-priority": "10",
      // A Lock Screen update delivered minutes late is worse than none.
      "apns-expiration": String(Math.floor(Date.now() / 1000) + 30),
      "content-type": "application/json",
    };
  }

  /** ES256 JWT, reused for 30 minutes, from memory or the store. */
  async providerToken(now = Date.now()): Promise<string> {
    if (this.usable(this.jwt, now)) return this.jwt.token;
    const stored = await this.store?.get();
    if (this.usable(stored, now)) {
      this.jwt = stored;
      return stored.token;
    }
    const header = base64url(new TextEncoder().encode(JSON.stringify({ alg: "ES256", kid: this.config.keyID })));
    const claims = base64url(new TextEncoder().encode(JSON.stringify({ iss: this.config.teamID, iat: Math.floor(now / 1000) })));
    const key = await crypto.subtle.importKey("pkcs8", pemToBytes(this.config.keyP8), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
    // Web Crypto gives the raw r‖s signature JWS wants.
    const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(`${header}.${claims}`));
    const token = `${header}.${claims}.${base64url(signature)}`;
    this.jwt = { token, issuedAt: now, keyID: this.config.keyID, teamID: this.config.teamID };
    await this.store?.put(this.jwt);
    return token;
  }

  private usable(token: ProviderToken | undefined, now: number): token is ProviderToken {
    if (!token || token.keyID !== this.config.keyID || token.teamID !== this.config.teamID) return false;
    const age = now - token.issuedAt;
    return age >= 0 && age < PROVIDER_TOKEN_REUSE_MS;
  }
}

function pemToBytes(pem: string): Uint8Array {
  const body = pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  return Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
}
