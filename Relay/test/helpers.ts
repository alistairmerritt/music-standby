import { env, exports } from "cloudflare:workers";
import { runInDurableObject } from "cloudflare:test";
import type { PlaybackMessage, RelayFrame } from "../src/protocol";

export const BASE = "https://relay.test";
let requestCount = 0;

export async function call(
  method: string,
  path: string,
  options: { token?: string; body?: unknown; headers?: Record<string, string>; raw?: BodyInit } = {},
): Promise<Response> {
  // Each request comes from its own address unless a test says otherwise, so
  // per-address rate limits only bite in the test about them.
  const headers: Record<string, string> = { "CF-Connecting-IP": `192.0.2.${(requestCount = (requestCount + 1) % 250)}`, ...(options.headers ?? {}) };
  if (options.token) headers.Authorization = `Bearer ${options.token}`;
  let body: BodyInit | undefined = options.raw;
  if (options.body !== undefined) {
    headers["Content-Type"] ??= "application/json";
    body = JSON.stringify(options.body);
  }
  return exports.default.fetch(new Request(`${BASE}${path}`, { method, headers, body }));
}

export const macDevice = { id: "6F9619FF-8B86-D011-B42D-00C04FC964FF", name: "Studio Mac", kind: "mac", appVersion: "test" };
export const phoneDevice = { id: "A3D1C2B4-0E5F-4A6B-9C7D-8E9F0A1B2C3D", name: "Alistair's iPhone", kind: "iphone" };

let address = 0;
export async function createMac(): Promise<{ pairingID: string; macToken: string }> {
  // A fresh address each time, so the per-address creation limit isn't what's tested.
  address += 1;
  const response = await call("POST", "/v1/pairings", { body: { device: macDevice }, headers: { "CF-Connecting-IP": `198.51.100.${address}` } });
  if (response.status !== 201) throw new Error(`create pairing: ${response.status} ${await response.text()}`);
  return response.json();
}

/** A Mac on the other end of the relay's WebSocket. */
export class MacSocket {
  readonly frames: RelayFrame[] = [];
  closed?: { code: number; reason: string };
  private waiting: Array<() => void> = [];

  private constructor(readonly ws: WebSocket) {
    ws.addEventListener("message", (event) => {
      this.frames.push(JSON.parse(event.data as string));
      this.waiting.splice(0).forEach((w) => w());
    });
    ws.addEventListener("close", (event) => {
      this.closed = { code: event.code, reason: event.reason };
      this.waiting.splice(0).forEach((w) => w());
    });
  }

  static async connect(macToken: string, hello = true): Promise<MacSocket> {
    const response = await exports.default.fetch(
      new Request(`${BASE}/v1/mac/socket`, { headers: { Upgrade: "websocket", Authorization: `Bearer ${macToken}` } }),
    );
    if (response.status !== 101 || !response.webSocket) throw new Error(`socket: ${response.status} ${await response.text()}`);
    response.webSocket.accept();
    const mac = new MacSocket(response.webSocket);
    if (hello) {
      mac.send({ type: "hello", protocolVersion: 1, device: macDevice });
      await mac.next("welcome");
    }
    return mac;
  }

  send(frame: unknown): void {
    this.ws.send(JSON.stringify(frame));
  }

  /** The first not-yet-taken frame of this type, waiting up to `ms`. */
  async next<T extends RelayFrame["type"]>(type: T, ms = 2000): Promise<Extract<RelayFrame, { type: T }>> {
    const deadline = Date.now() + ms;
    for (;;) {
      const index = this.frames.findIndex((f) => f.type === type);
      if (index >= 0) return this.frames.splice(index, 1)[0] as Extract<RelayFrame, { type: T }>;
      if (this.closed || Date.now() > deadline) throw new Error(`no ${type} frame (closed: ${JSON.stringify(this.closed)})`);
      await new Promise<void>((resolve) => {
        this.waiting.push(resolve);
        setTimeout(resolve, 50);
      });
    }
  }

  async waitForClose(ms = 2000): Promise<{ code: number; reason: string }> {
    const deadline = Date.now() + ms;
    while (!this.closed && Date.now() < deadline) await new Promise((r) => setTimeout(r, 20));
    if (!this.closed) throw new Error("socket did not close");
    return this.closed;
  }

  close(code = 1000): void {
    this.ws.close(code, "test");
  }
}

/** Runs the whole pairing flow; returns the phone's credential. */
export async function pairPhone(mac: MacSocket, macToken: string): Promise<string> {
  const code = (await (await call("POST", "/v1/pairing/code", { token: macToken })).json()) as { code: string };
  const claim = (await (await call("POST", "/v1/pairing/claim", { body: { code: code.code, phone: phoneDevice } })).json()) as {
    claimID: string;
    claimSecret: string;
  };
  const request = await mac.next("pair-request");
  mac.send({ type: "pair-decision", claimID: request.request.claimID, approved: true });
  for (let i = 0; i < 40; i++) {
    const status = (await (await call("GET", `/v1/pairing/claim/${claim.claimID}`, { token: claim.claimSecret })).json()) as {
      status: string;
      phoneToken?: string;
    };
    if (status.status === "approved") {
      await mac.next("paired");
      return status.phoneToken!;
    }
    await new Promise((r) => setTimeout(r, 20));
  }
  throw new Error("pairing never approved");
}

let revision = 1_794_207_600_000;
export function playback(overrides: Partial<PlaybackMessage> = {}): PlaybackMessage {
  revision += 1;
  return {
    revision,
    state: "playing",
    isPlaying: true,
    elapsedTime: 12.5,
    capturedAt: new Date().toISOString(),
    track: { id: "pid:542CEB17C137B39E", title: "Losing My Edge", artist: "LCD Soundsystem", album: "LCD Soundsystem", duration: 473.114 },
    canGoNext: true,
    canGoPrevious: true,
    listeningSessionID: "0C7E4A52-3D2B-4F3E-9A61-6B1F2E8D9C10",
    ...overrides,
  };
}

export async function session(phoneToken: string): Promise<any> {
  return (await call("GET", "/v1/session", { token: phoneToken })).json();
}

/** Polls until the relay has applied a state with this revision. */
export async function waitForRevision(phoneToken: string, rev: number): Promise<any> {
  for (let i = 0; i < 100; i++) {
    const s = await session(phoneToken);
    if (s.playback?.revision === rev) return s;
    await new Promise((r) => setTimeout(r, 10));
  }
  throw new Error(`relay never applied revision ${rev}`);
}

export async function pushes(token: string): Promise<any[]> {
  return ((await (await call("GET", "/v1/dev/pushes", { token })).json()) as { pushes: any[] }).pushes;
}

export function pairingStub(pairingID: string) {
  return env.PAIRING.get(env.PAIRING.idFromName(pairingID));
}

export async function editStorage(pairingID: string, edit: (storage: DurableObjectStorage) => Promise<void>): Promise<void> {
  await runInDurableObject(pairingStub(pairingID), async (_instance, state) => edit(state.storage));
}

export function directoryStub() {
  return env.DIRECTORY.get(env.DIRECTORY.idFromName("directory"));
}

export function newCommandID(): string {
  return crypto.randomUUID().toUpperCase();
}
