// Remote Now Playing pushes, per Apple's "Publishing remote media sessions":
// push type `nowplaying`, topic `<bundle id>.push-type.nowplaying`, `start` to
// the push-to-start token, `update` and `end` to the session's own token.
//
// MockPushSender records pushes; APNsPushSender sends them. APNs answers only
// over HTTP/2, which a deployed Worker has and local workerd doesn't.

import { base64url } from "./crypto";
import type { HandBackRequest, NowPlayingAttributes } from "./protocol";

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
  sendAlert(push: AlertPush): Promise<PushResult>;
  sendBackground(push: BackgroundPush): Promise<PushResult>;
}

/**
 * An ordinary notification to the app, not a Now Playing push: the reminder
 * to open it. iOS shows a remote session only once the app has asked while
 * open, so a dismissed player stays hidden until the app is opened.
 */
export interface AlertPush {
  token: string;
  /** Each reminder replaces the last, so they never pile up. */
  collapseID: string;
  payload: {
    aps: { alert: { title: string; body: string }; "thread-id": string; "interruption-level": "time-sensitive"; "relevance-score": number };
    /** Continue from iPhone's notification (API-v1 §14). */
    handBack?: HandBackRequest;
  };
}

/**
 * A background push: it wakes the app without showing anything, and needs no
 * notification permission. iOS delivers it when it sees fit (API-v1 §14).
 */
export interface BackgroundPush {
  token: string;
  payload: { aps: { "content-available": 1 }; handBack: HandBackRequest };
}

export const REMINDER_ID = "mac-playing";
export const HAND_BACK_ID = "hand-back";

/** Continue from iPhone, first try: wake the app to hand the music back. */
export function makeHandBackWake(token: string, request: HandBackRequest): BackgroundPush {
  return { token, payload: { aps: { "content-available": 1 }, handBack: request } };
}

/**
 * Continue from iPhone, second try, when the background push got no answer:
 * a notification whose tap hands back. Time Sensitive and silent, like the
 * reminder, and one at a time.
 */
export function makeHandBackAlert(token: string, macName: string, request: HandBackRequest): AlertPush {
  return {
    token,
    collapseID: HAND_BACK_ID,
    payload: {
      aps: {
        alert: { title: `Continue on ${macName}?`, body: "Tap to play this song on your Mac from where you are." },
        "thread-id": HAND_BACK_ID,
        "interruption-level": "time-sensitive",
        "relevance-score": 1,
      },
      handBack: request,
    },
  };
}

/**
 * No sound: the reminder should be noticed, not heard. Time Sensitive, so it
 * shows during a Focus, in a scheduled Summary and in StandBy: as an ordinary
 * ("active") alert it went straight to Notification Centre whenever a Focus
 * was on, which in StandBy is most of the time (seen 12 Nov 2026). The app
 * carries the Time Sensitive entitlement; the person can still turn it off
 * per app or per Focus in Settings.
 */
export function makeReminder(token: string, macName: string): AlertPush {
  return {
    token,
    collapseID: REMINDER_ID,
    payload: {
      aps: {
        alert: { title: `Music playing on ${macName}`, body: "Tap to show on your Lock Screen." },
        "thread-id": REMINDER_ID,
        "interruption-level": "time-sensitive",
        "relevance-score": 1,
      },
    },
  };
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
  constructor(private readonly record: (push: Push | AlertPush | BackgroundPush) => Promise<void>) {}
  async send(push: Push): Promise<PushResult> {
    await this.record(push);
    return { status: 200 };
  }
  async sendAlert(push: AlertPush): Promise<PushResult> {
    await this.record(push);
    return { status: 200 };
  }
  async sendBackground(push: BackgroundPush): Promise<PushResult> {
    await this.record(push);
    return { status: 200 };
  }
}

export type APNsEnvironment = "development" | "production";

export interface APNsConfig {
  keyP8: string;
  keyID: string;
  teamID: string;
  topic: string;
  /** The app's own topic for alert pushes; defaults to `topic` without ".push-type.nowplaying". */
  appTopic?: string;
  /** Where a pairing's pushes go until one has been delivered elsewhere. */
  environment: APNsEnvironment;
}

/**
 * Which APNs environment a pairing's phone turned out to use. Builds from Xcode
 * get sandbox tokens; TestFlight and App Store builds get production ones, and
 * nothing in a token says which. Every token of one phone comes from one build,
 * so one answer per pairing is enough.
 */
export interface EnvironmentStore {
  get(): Promise<APNsEnvironment | undefined>;
  put(environment: APNsEnvironment): Promise<void>;
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
  private learned?: APNsEnvironment;

  constructor(
    private readonly config: APNsConfig,
    // Called through a wrapper: Workers throw "Illegal invocation" when the
    // global fetch is called as a method of another object.
    private readonly fetcher: typeof fetch = (input, init) => fetch(input, init),
    private readonly store?: ProviderTokenStore,
    private readonly environments?: EnvironmentStore,
  ) {}

  /** The host pushes go to first: the environment learned, else the configured one. */
  get host(): string {
    return hostFor(this.learned ?? this.config.environment);
  }

  /** The environment the next push goes to first. */
  async environment(): Promise<APNsEnvironment> {
    this.learned ??= await this.environments?.get();
    return this.learned ?? this.config.environment;
  }

  async send(push: Push): Promise<PushResult> {
    return this.post(push.token, this.headers(push, await this.providerToken()), push.payload);
  }

  async sendAlert(push: AlertPush): Promise<PushResult> {
    return this.post(push.token, this.alertHeaders(push, await this.providerToken()), push.payload);
  }

  async sendBackground(push: BackgroundPush): Promise<PushResult> {
    return this.post(push.token, this.backgroundHeaders(await this.providerToken()), push.payload);
  }

  /** Apple: a background push must have priority 5 and the app's own topic. */
  backgroundHeaders(jwt: string): Record<string, string> {
    return {
      authorization: `bearer ${jwt}`,
      "apns-push-type": "background",
      "apns-topic": this.appTopic,
      "apns-priority": "5",
      // The request is forgotten after 2 minutes; a later wake would surprise.
      "apns-expiration": String(Math.floor(Date.now() / 1000) + 2 * 60),
      "content-type": "application/json",
    };
  }

  private get appTopic(): string {
    return this.config.appTopic ?? this.config.topic.replace(/\.push-type\.nowplaying$/, "");
  }

  alertHeaders(push: AlertPush, jwt: string): Record<string, string> {
    return {
      authorization: `bearer ${jwt}`,
      "apns-push-type": "alert",
      "apns-topic": this.appTopic,
      "apns-priority": "10",
      "apns-collapse-id": push.collapseID,
      // A reminder that arrives much later than the music started is noise;
      // a hand-back prompt outlives its request by no more than that request.
      "apns-expiration": String(Math.floor(Date.now() / 1000) + (push.collapseID === HAND_BACK_ID ? 2 : 10) * 60),
      "content-type": "application/json",
    };
  }

  /**
   * APNs answers BadDeviceToken to a token sent to the wrong environment
   * (Apple: "…and that the token matches the environment"), so that answer is
   * tried once against the other one. Delivered there, that environment is
   * kept for the pairing. Refused by both, the token is dead as before.
   */
  private async post(token: string, headers: Record<string, string>, payload: unknown): Promise<PushResult> {
    const first = await this.environment();
    const result = await this.attempt(first, token, headers, payload);
    if (result.status !== 400 || result.reason !== "BadDeviceToken") return result;
    const other: APNsEnvironment = first === "production" ? "development" : "production";
    const retry = await this.attempt(other, token, headers, payload);
    if (retry.status >= 200 && retry.status < 300) {
      console.log(`push: token is for APNs ${other}, not ${first}; using ${other} from now on`);
      this.learned = other;
      await this.environments?.put(other);
    }
    return retry;
  }

  private async attempt(environment: APNsEnvironment, token: string, headers: Record<string, string>, payload: unknown): Promise<PushResult> {
    const response = await this.fetcher(`${hostFor(environment)}/3/device/${token}`, {
      method: "POST",
      headers,
      body: JSON.stringify(payload),
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

function hostFor(environment: APNsEnvironment): string {
  return environment === "production" ? "https://api.push.apple.com" : "https://api.sandbox.push.apple.com";
}

function pemToBytes(pem: string): Uint8Array {
  const body = pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  return Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
}
