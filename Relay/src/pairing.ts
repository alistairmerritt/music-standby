import { DurableObject } from "cloudflare:workers";
import { bearer, hex, newToken, parseToken, randomBytes, sameHash, sha256Hex, sign, verifySignature, newPairingCode } from "./crypto";
import { directory, type Env } from "./env";
import { HttpError, empty, errorResponse, json, readJSON } from "./http";
import {
  ARTWORK_ID,
  HEX_TOKEN,
  PROTOCOL_VERSION,
  endsSession,
  isAck,
  isCommand,
  isPlaybackMessage,
  stateOf,
  type CommandAck,
  type DeviceIdentity,
  type MacFrame,
  type NowPlayingAttributes,
  type PairedMac,
  type PlaybackMessage,
  type RelayFrame,
  type RemoteCommand,
} from "./protocol";
import { APNsPushSender, MockPushSender, makePush, tokenIsDead, type ProviderToken, type Push, type PushEvent, type PushSender } from "./push";

// One Durable Object per pairing (one Mac, at most one phone). It holds the
// credentials' hashes, the Mac's WebSocket, the latest playback, the Now
// Playing session and its push tokens, recent command acks and artwork.

interface PairingRecord {
  pairingID: string;
  mac: DeviceIdentity;
  macTokenHash: string;
  phone?: DeviceIdentity;
  phoneTokenHash?: string;
  /** HMAC key for artwork capability URLs; changes with the pairing. */
  artworkKey: string;
  baseURL?: string;
  createdAt: number;
}

interface Claim {
  claimID: string;
  secretHash: string;
  phone: DeviceIdentity;
  expiresAt: number;
  status: "pending" | "approved" | "denied";
}

interface Session {
  sessionID: string;
  listeningSessionID?: string;
  startedAt: number;
  /** Revision of the last state actually pushed. */
  pushedRevision: number;
  pausedSince?: number;
}

interface PushTokens {
  start?: string;
  session?: { sessionID: string; token: string };
}

interface StoredArtwork {
  contentType: string;
  data: ArrayBuffer;
}

interface RecordedPush {
  at: string;
  event: PushEvent;
  sessionID: string;
  status: number;
  payload: Push["payload"];
}

const ARTWORK_MAX_BYTES = 1024 * 1024;
const ARTWORK_KEEP = 64;
/**
 * A GET for artwork the Mac was asked for this recently waits for the upload
 * instead of answering 404 at once. The phone learns an artwork id from the
 * same state that makes the relay ask, so it can ask first: seen on an
 * iPhone, one download got 404 and another 100 ms later got the image.
 */
const ARTWORK_PENDING_MS = 10_000;
const ARTWORK_UPLOAD_WAIT_MS = 3_000;
const ACKS_KEEP = 50;
const PUSHES_KEEP = 100;

export class Pairing extends DurableObject<Env> {
  /** Commands waiting for the Mac's ack, by lowercased command id. */
  private waiters = new Map<string, { promise: Promise<CommandAck>; resolve: (ack: CommandAck) => void }>();
  /** Artwork ids asked for since this instance woke, with when. */
  private requested = new Map<string, number>();
  /** Artwork GETs waiting for the Mac's upload, by artwork id. */
  private artworkWaiters = new Map<string, Set<() => void>>();
  /** Kept so pushes reuse one provider token; see ProviderTokenStore. */
  private apns?: APNsPushSender;

  private get ackTimeout(): number {
    return Number(this.env.ACK_TIMEOUT_MS ?? 1200);
  }
  private get disconnectGrace(): number {
    return Number(this.env.DISCONNECT_GRACE_MS ?? 60_000);
  }
  private get pausedTimeout(): number {
    return Number(this.env.PAUSED_TIMEOUT_MS ?? 15 * 60_000);
  }

  // MARK: RPC from the Worker

  async create(pairingID: string, mac: DeviceIdentity, macTokenHash: string): Promise<void> {
    const record: PairingRecord = { pairingID, mac, macTokenHash, artworkKey: hex(randomBytes(32)), createdAt: Date.now() };
    await this.ctx.storage.put("record", record);
    console.log(`pairing ${short(pairingID)}: created for "${mac.name}"`);
  }

  /** Records a claim made with this pairing's code. Nil if the pairing is gone. */
  async addClaim(claimID: string, phone: DeviceIdentity, secretHash: string, expiresAt: number): Promise<PairedMac | null> {
    const record = await this.record();
    if (!record) return null;
    const claims = await this.claims();
    claims[claimID] = { claimID, secretHash, phone, expiresAt, status: "pending" };
    await this.ctx.storage.put("claims", claims);
    this.sendToMac({ type: "pair-request", request: { claimID, phone, expiresAt: iso(expiresAt) } });
    await this.scheduleAlarm();
    console.log(`pairing ${short(record.pairingID)}: claim from "${phone.name}" waiting for the Mac`);
    return { id: record.mac.id, name: record.mac.name };
  }

  // MARK: HTTP and WebSocket entry

  async fetch(request: Request): Promise<Response> {
    try {
      return await this.route(request);
    } catch (e) {
      if (e instanceof HttpError) return errorResponse(e);
      console.error(`pairing: unhandled ${(e as Error).message}`);
      return errorResponse(new HttpError(500, "internal"));
    }
  }

  private async route(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const path = url.pathname;
    const method = request.method;
    const record = await this.record();

    const artwork = /^\/v1\/artwork\/[0-9a-f]{32}\/([0-9a-f]{64})$/.exec(path);
    if (artwork && method === "GET") {
      if (!record) throw new HttpError(404, "not_found");
      return this.getArtwork(request, url, record, artwork[1]);
    }

    const token = bearer(request);
    const parsed = parseToken(token);
    if (!record || !parsed || !token) throw new HttpError(401, "unauthorized");
    const hash = await sha256Hex(token);

    if (parsed.kind === "claim") {
      const claim = /^\/v1\/pairing\/claim\/([0-9a-f]{32})$/.exec(path);
      if (!claim || method !== "GET") throw new HttpError(401, "unauthorized");
      return this.claimStatus(record, claim[1], hash);
    }

    const isMac = parsed.kind === "mac" && sameHash(hash, record.macTokenHash);
    const isPhone = parsed.kind === "phone" && sameHash(hash, record.phoneTokenHash);
    if (!isMac && !isPhone) throw new HttpError(401, "unauthorized");

    // Either side
    if (method === "DELETE" && path === "/v1/pairing") return this.unpair(record, isMac ? "mac" : "phone");
    if (method === "GET" && path === "/v1/dev/pushes" && this.env.DEV_ENDPOINTS === "1") {
      return json(200, { pushes: (await this.ctx.storage.get<RecordedPush[]>("pushes")) ?? [] });
    }

    if (isMac) {
      if (path === "/v1/mac/socket") return this.acceptMac(request, record);
      if (method === "POST" && path === "/v1/pairing/code") return this.newCode(record);
      const put = /^\/v1\/artwork\/([0-9a-f]{64})$/.exec(path);
      if (put && method === "PUT") return this.putArtwork(request, put[1]);
      throw new HttpError(404, "not_found");
    }

    // Phone
    if (method === "POST" && path === "/v1/commands") return this.command(request);
    if (method === "GET" && path === "/v1/session") return json(200, await this.sessionState(record));
    if (method === "PUT" && path === "/v1/tokens/start") return this.putStartToken(request);
    if (method === "PUT" && path === "/v1/tokens/session") return this.putSessionToken(request, record);
    const deleteToken = /^\/v1\/tokens\/session\/([^/]+)$/.exec(path);
    if (deleteToken && method === "DELETE") return this.deleteSessionToken(decodeURIComponent(deleteToken[1]));
    if (method === "POST" && path === "/v1/session/end") return this.phoneEndsSession(request);
    throw new HttpError(404, "not_found");
  }

  // MARK: Pairing

  private async newCode(record: PairingRecord): Promise<Response> {
    const code = newPairingCode();
    const expiresAt = await directory(this.env).registerCode(record.pairingID, code);
    console.log(`pairing ${short(record.pairingID)}: new pairing code issued`);
    return json(201, { code, expiresAt: iso(expiresAt) });
  }

  private async claimStatus(record: PairingRecord, claimID: string, secretHash: string): Promise<Response> {
    const claims = await this.claims();
    const claim = claims[claimID];
    if (!claim || !sameHash(secretHash, claim.secretHash)) throw new HttpError(410, "claim_expired");
    if (claim.expiresAt <= Date.now()) {
      delete claims[claimID];
      await this.ctx.storage.put("claims", claims);
      throw new HttpError(410, "claim_expired");
    }
    if (claim.status === "pending") return json(200, { status: "pending" });
    delete claims[claimID];
    await this.ctx.storage.put("claims", claims);
    if (claim.status === "denied") return json(200, { status: "denied" });

    // Approved: the phone's credential is minted now and handed over once.
    if (record.phoneTokenHash) {
      await this.endSession("phone_replaced");
      await this.ctx.storage.delete("tokens");
    }
    const phoneToken = newToken("phone", record.pairingID);
    record.phone = claim.phone;
    record.phoneTokenHash = await sha256Hex(phoneToken);
    await this.ctx.storage.put("record", record);
    this.sendToMac({ type: "paired", phone: claim.phone });
    console.log(`pairing ${short(record.pairingID)}: paired with "${claim.phone.name}"`);
    return json(200, { status: "approved", pairingID: record.pairingID, phoneToken, mac: { id: record.mac.id, name: record.mac.name } });
  }

  private async decide(claimID: string, approved: boolean): Promise<void> {
    const claims = await this.claims();
    const claim = claims[claimID];
    if (!claim || claim.status !== "pending" || claim.expiresAt <= Date.now()) {
      this.sendToMac({ type: "error", error: { code: "claim_expired", message: `no pending claim ${claimID}` } });
      return;
    }
    claim.status = approved ? "approved" : "denied";
    await this.ctx.storage.put("claims", claims);
    console.log(`pairing: claim ${short(claimID)} ${claim.status} on the Mac`);
  }

  private async unpair(record: PairingRecord, by: "mac" | "phone"): Promise<Response> {
    await this.endSession("unpaired");
    for (const ws of this.ctx.getWebSockets("mac")) {
      try {
        ws.send(JSON.stringify({ type: "revoked", reason: "unpaired" } satisfies RelayFrame));
        ws.close(4410, "revoked");
      } catch {
        // already closing
      }
    }
    await directory(this.env).removeCodeFor(record.pairingID);
    await this.ctx.storage.deleteAlarm();
    await this.ctx.storage.deleteAll();
    console.log(`pairing ${short(record.pairingID)}: unpaired by the ${by}; all credentials revoked`);
    return empty();
  }

  // MARK: Mac WebSocket

  private async acceptMac(request: Request, record: PairingRecord): Promise<Response> {
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      throw new HttpError(400, "invalid_request", "expected a WebSocket upgrade");
    }
    for (const old of this.ctx.getWebSockets("mac")) {
      try {
        old.close(4409, "replaced by a newer connection");
      } catch {
        // already closed
      }
    }
    const [client, server] = Object.values(new WebSocketPair());
    this.ctx.acceptWebSocket(server, ["mac"]);
    if (!this.env.PUBLIC_BASE_URL) {
      record.baseURL = new URL(request.url).origin;
      await this.ctx.storage.put("record", record);
    }
    await this.ctx.storage.delete(["macDisconnectedAt", "goodbye"]);
    await this.scheduleAlarm();
    console.log(`pairing ${short(record.pairingID)}: Mac connected`);
    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(ws: WebSocket, raw: string | ArrayBuffer): Promise<void> {
    let frame: MacFrame;
    try {
      frame = JSON.parse(typeof raw === "string" ? raw : new TextDecoder().decode(raw));
    } catch {
      this.send(ws, { type: "error", error: { code: "invalid_frame", message: "not JSON" } });
      return;
    }
    switch (frame.type) {
      case "hello": {
        if (frame.protocolVersion !== PROTOCOL_VERSION) {
          this.send(ws, { type: "error", error: { code: "unsupported_protocol_version", message: `this relay speaks ${PROTOCOL_VERSION}` } });
          ws.close(4400, "unsupported protocol version");
          return;
        }
        const record = await this.record();
        this.send(ws, { type: "welcome", protocolVersion: PROTOCOL_VERSION });
        if (record?.phone) this.send(ws, { type: "paired", phone: record.phone });
        const now = Date.now();
        for (const claim of Object.values(await this.claims())) {
          if (claim.status === "pending" && claim.expiresAt > now) {
            this.send(ws, { type: "pair-request", request: { claimID: claim.claimID, phone: claim.phone, expiresAt: iso(claim.expiresAt) } });
          }
        }
        return;
      }
      case "state":
        return this.applyState(ws, frame.message);
      case "ack":
        return this.receiveAck(frame.ack);
      case "goodbye":
        await this.ctx.storage.put("goodbye", true);
        await this.endSession("mac_goodbye");
        return;
      case "pair-decision":
        return this.decide(String(frame.claimID), frame.approved === true);
      case "error":
        // The Mac can't supply artwork it was asked for: stop holding its GETs.
        if (frame.error?.code === "artwork_unavailable" && typeof frame.error.message === "string") {
          this.requested.delete(frame.error.message);
          this.releaseArtworkWaiters(frame.error.message);
        }
        return;
      case "artwork":
        return;
      default:
        // Unknown frame types are ignored (PROTOCOL.md §1).
        return;
    }
  }

  async webSocketClose(ws: WebSocket, code: number): Promise<void> {
    const others = this.ctx.getWebSockets("mac").filter((s) => s !== ws && s.readyState === WebSocket.OPEN);
    if (others.length > 0 || code === 4409) return;
    const said = await this.ctx.storage.get<boolean>("goodbye");
    if (said) {
      await this.ctx.storage.delete("goodbye");
    } else {
      await this.ctx.storage.put("macDisconnectedAt", Date.now());
    }
    await this.scheduleAlarm();
    console.log(`pairing: Mac disconnected (${code})${said ? " after goodbye" : ""}`);
  }

  async webSocketError(ws: WebSocket): Promise<void> {
    await this.webSocketClose(ws, 1006);
  }

  // MARK: Playback and sessions

  private async applyState(ws: WebSocket, message: PlaybackMessage): Promise<void> {
    if (!isPlaybackMessage(message)) {
      this.send(ws, { type: "error", error: { code: "invalid_frame", message: "state.message is not a PlaybackMessage" } });
      return;
    }
    const previous = await this.ctx.storage.get<PlaybackMessage>("playback");
    if (previous && message.revision < previous.revision) return; // stale (PROTOCOL.md §4)
    await this.ctx.storage.put("playback", message);

    const art = message.track?.artworkID;
    if (art && ARTWORK_ID.test(art) && !this.requested.has(art) && !(await this.ctx.storage.get(`art:${art}`))) {
      this.requested.set(art, Date.now());
      this.send(ws, { type: "artwork-request", artworkID: art });
    }

    const state = stateOf(message);
    let session = await this.ctx.storage.get<Session>("session");
    if (session && endsSession(state)) {
      await this.endSession(`mac_${state}`);
      return;
    }
    if (session && message.listeningSessionID && session.listeningSessionID && message.listeningSessionID !== session.listeningSessionID) {
      await this.endSession("new_listening_session");
      session = undefined;
    }
    if (!session) {
      if (state !== "playing") return;
      // A session the phone dismissed stays dismissed for that listening session.
      const dismissed = await this.ctx.storage.get<string>("dismissed");
      if (dismissed && message.listeningSessionID === dismissed) return;
      await this.ctx.storage.delete("dismissed");
      await this.startSession(message);
      return;
    }
    session.listeningSessionID ??= message.listeningSessionID;
    session.pausedSince = state === "paused" ? (session.pausedSince ?? Date.now()) : undefined;
    await this.ctx.storage.put("session", session);
    if (message.revision > session.pushedRevision) await this.pushUpdate(session, message);
    await this.scheduleAlarm();
  }

  private async startSession(message: PlaybackMessage): Promise<void> {
    const session: Session = {
      sessionID: crypto.randomUUID(),
      listeningSessionID: message.listeningSessionID,
      startedAt: Date.now(),
      pushedRevision: message.revision,
    };
    await this.ctx.storage.put("session", session);
    console.log(`session ${short(session.sessionID)}: started`);
    const tokens = await this.tokens();
    if (tokens.start) {
      await this.push("start", tokens.start, await this.attributes(session, message));
    } else {
      console.log(`session ${short(session.sessionID)}: no push-to-start token; the phone must foreground to see it`);
    }
    await this.scheduleAlarm();
  }

  private async pushUpdate(session: Session, message: PlaybackMessage): Promise<void> {
    const tokens = await this.tokens();
    const token = tokens.session?.sessionID === session.sessionID ? tokens.session.token : undefined;
    if (!token) return; // sent when the extension registers its token
    const ok = await this.push("update", token, await this.attributes(session, message));
    if (ok) {
      session.pushedRevision = message.revision;
      await this.ctx.storage.put("session", session);
    }
  }

  async endSession(reason: string): Promise<void> {
    const session = await this.ctx.storage.get<Session>("session");
    if (!session) return;
    await this.ctx.storage.delete("session");
    const tokens = await this.tokens();
    if (tokens.session?.sessionID === session.sessionID) {
      const token = tokens.session.token;
      delete tokens.session;
      await this.ctx.storage.put("tokens", tokens);
      await this.push("end", token, { id: session.sessionID } as NowPlayingAttributes);
    }
    console.log(`session ${short(session.sessionID)}: ended (${reason})`);
    await this.scheduleAlarm();
  }

  private async attributes(session: Session, message: PlaybackMessage): Promise<NowPlayingAttributes> {
    const record = (await this.record())!;
    const track = message.track;
    let artworkURL: string | undefined;
    if (track?.artworkID && ARTWORK_ID.test(track.artworkID)) {
      const base = this.env.PUBLIC_BASE_URL ?? record.baseURL ?? "";
      const sig = await sign(record.artworkKey, track.artworkID);
      artworkURL = `${base}/v1/artwork/${record.pairingID}/${track.artworkID}?sig=${sig}`;
    }
    return {
      id: session.sessionID,
      macName: record.mac.name,
      revision: message.revision,
      isPlaying: stateOf(message) === "playing",
      elapsedTime: message.elapsedTime,
      timestamp: message.capturedAt,
      track: track
        ? {
            id: track.id,
            title: track.title,
            artist: track.artist,
            album: track.album,
            duration: track.duration,
            artworkID: track.artworkID ?? "",
            ...(artworkURL ? { artworkURL } : {}),
          }
        : undefined,
      canGoNext: message.canGoNext,
      canGoPrevious: message.canGoPrevious,
    };
  }

  private async sessionState(record: PairingRecord) {
    const session = await this.ctx.storage.get<Session>("session");
    const playback = await this.ctx.storage.get<PlaybackMessage>("playback");
    return {
      ...(session ? { sessionID: session.sessionID } : {}),
      mac: { id: record.mac.id, name: record.mac.name },
      macConnected: this.macSocket() !== undefined,
      ...(playback ? { playback } : {}),
      ...(session && playback ? { attributes: await this.attributes(session, playback) } : {}),
    };
  }

  // MARK: Commands

  private async command(request: Request): Promise<Response> {
    const body = await readJSON<{ command?: RemoteCommand; sessionID?: string }>(request);
    if (!isCommand(body?.command)) throw new HttpError(400, "invalid_request", "command must have a UUID id and a kind");
    const command = body.command;
    const key = request.headers.get("Idempotency-Key");
    if (!key || key.toLowerCase() !== command.id.toLowerCase()) {
      throw new HttpError(400, "invalid_request", "Idempotency-Key must equal command.id");
    }
    const id = command.id.toLowerCase();

    const stored = await this.storedAck(id);
    if (stored) return json(200, { ack: stored });
    const inflight = this.waiters.get(id);
    if (inflight) return this.awaitAck(inflight.promise);

    if (!body.sessionID) throw new HttpError(400, "invalid_request", "sessionID is required");
    const session = await this.ctx.storage.get<Session>("session");
    if (!session) throw new HttpError(409, "no_session", "there is no current session");
    if (body.sessionID !== session.sessionID) throw new HttpError(409, "session_mismatch", "the command names an earlier session");

    const mac = this.macSocket();
    if (!mac) throw new HttpError(504, "mac_unreachable", "the Mac is not connected");

    let resolve!: (ack: CommandAck) => void;
    const promise = new Promise<CommandAck>((r) => (resolve = r));
    this.waiters.set(id, { promise, resolve });
    setTimeout(() => this.waiters.delete(id), 30_000);
    this.send(mac, { type: "command", command });
    console.log(`session ${short(session.sessionID)}: command ${command.kind} sent to the Mac`);
    return this.awaitAck(promise);
  }

  private async awaitAck(promise: Promise<CommandAck>): Promise<Response> {
    let timer: number | undefined;
    const timeout = new Promise<null>((r) => (timer = setTimeout(() => r(null), this.ackTimeout)));
    const ack = await Promise.race([promise, timeout]);
    if (timer !== undefined) clearTimeout(timer);
    if (!ack) throw new HttpError(504, "mac_unreachable", `no acknowledgement within ${this.ackTimeout} ms`);
    return json(200, { ack });
  }

  private async receiveAck(ack: CommandAck): Promise<void> {
    if (!isAck(ack)) return;
    const id = ack.commandID.toLowerCase();
    const acks = (await this.ctx.storage.get<[string, CommandAck][]>("acks")) ?? [];
    if (!acks.some(([k]) => k === id)) {
      acks.push([id, ack]);
      await this.ctx.storage.put("acks", acks.slice(-ACKS_KEEP));
    }
    this.waiters.get(id)?.resolve(ack);
    this.waiters.delete(id);
    console.log(`command ${short(id)}: ${ack.accepted ? "accepted" : `rejected (${ack.error?.code ?? "?"})`}`);
  }

  private async storedAck(id: string): Promise<CommandAck | undefined> {
    const acks = (await this.ctx.storage.get<[string, CommandAck][]>("acks")) ?? [];
    return acks.find(([k]) => k === id)?.[1];
  }

  // MARK: Push tokens

  private async putStartToken(request: Request): Promise<Response> {
    const body = await readJSON<{ token?: string }>(request);
    if (!body?.token || !HEX_TOKEN.test(body.token)) throw new HttpError(400, "invalid_request", "token must be hex");
    const tokens = await this.tokens();
    tokens.start = body.token.toLowerCase();
    await this.ctx.storage.put("tokens", tokens);
    return empty();
  }

  private async putSessionToken(request: Request, record: PairingRecord): Promise<Response> {
    const body = await readJSON<{ sessionID?: string; token?: string }>(request);
    if (!body?.sessionID || !body.token || !HEX_TOKEN.test(body.token)) {
      throw new HttpError(400, "invalid_request", "sessionID and a hex token are required");
    }
    const session = await this.ctx.storage.get<Session>("session");
    if (!session || session.sessionID !== body.sessionID) throw new HttpError(409, "session_mismatch");
    const tokens = await this.tokens();
    tokens.session = { sessionID: session.sessionID, token: body.token.toLowerCase() };
    await this.ctx.storage.put("tokens", tokens);
    // The ordering problem in relay design §6: catch up on what was held back.
    const playback = await this.ctx.storage.get<PlaybackMessage>("playback");
    if (playback && playback.revision > session.pushedRevision) await this.pushUpdate(session, playback);
    void record;
    return empty();
  }

  private async deleteSessionToken(sessionID: string): Promise<Response> {
    const tokens = await this.tokens();
    if (tokens.session?.sessionID === sessionID) {
      delete tokens.session;
      await this.ctx.storage.put("tokens", tokens);
    }
    return empty();
  }

  private async phoneEndsSession(request: Request): Promise<Response> {
    const body = await readJSON<{ sessionID?: string }>(request);
    const session = await this.ctx.storage.get<Session>("session");
    if (!session) throw new HttpError(409, "no_session");
    if (body?.sessionID !== session.sessionID) throw new HttpError(409, "session_mismatch");
    if (session.listeningSessionID) await this.ctx.storage.put("dismissed", session.listeningSessionID);
    await this.endSession("phone");
    return empty();
  }

  /** Sends one push and drops tokens APNs says are dead. True on success. */
  private async push(event: PushEvent, token: string, attributes: NowPlayingAttributes): Promise<boolean> {
    const push = makePush(event, token, attributes);
    const result = await this.pushSender().send(push);
    console.log(`session ${short(push.sessionID)}: ${event} push → ${result.status}${result.reason ? ` ${result.reason}` : ""}`);
    if (tokenIsDead(result)) {
      const tokens = await this.tokens();
      if (tokens.start === token) delete tokens.start;
      const wasSession = tokens.session?.token === token;
      if (wasSession) delete tokens.session;
      await this.ctx.storage.put("tokens", tokens);
      if (wasSession && event !== "end") await this.endSession("push_token_invalid");
    }
    return result.status >= 200 && result.status < 300;
  }

  private pushSender(): PushSender {
    const env = this.env;
    if (env.PUSH_MODE === "apns" && env.APNS_KEY_P8 && env.APNS_KEY_ID && env.APNS_TEAM_ID) {
      this.apns ??= new APNsPushSender(
        {
          keyP8: env.APNS_KEY_P8,
          keyID: env.APNS_KEY_ID,
          teamID: env.APNS_TEAM_ID,
          topic: env.APNS_TOPIC ?? "com.alistairmerritt.MusicStandBy.push-type.nowplaying",
          environment: env.APNS_ENVIRONMENT === "production" ? "production" : "development",
        },
        undefined,
        {
          get: () => this.ctx.storage.get<ProviderToken>("apnsProviderToken"),
          put: (token) => (token ? this.ctx.storage.put("apnsProviderToken", token) : this.ctx.storage.delete("apnsProviderToken").then(() => {})),
        },
      );
      return this.apns;
    }
    return new MockPushSender(async (push) => {
      const pushes = (await this.ctx.storage.get<RecordedPush[]>("pushes")) ?? [];
      pushes.push({ at: iso(Date.now()), event: push.event, sessionID: push.sessionID, status: 200, payload: push.payload });
      await this.ctx.storage.put("pushes", pushes.slice(-PUSHES_KEEP));
    });
  }

  // MARK: Artwork

  private async putArtwork(request: Request, artworkID: string): Promise<Response> {
    const contentType = (request.headers.get("Content-Type") ?? "").split(";")[0].trim().toLowerCase();
    if (contentType !== "image/jpeg" && contentType !== "image/png") {
      throw new HttpError(400, "invalid_request", "Content-Type must be image/jpeg or image/png");
    }
    if (Number(request.headers.get("Content-Length") ?? "0") > ARTWORK_MAX_BYTES) throw new HttpError(413, "payload_too_large");
    const data = await request.arrayBuffer();
    if (data.byteLength > ARTWORK_MAX_BYTES) throw new HttpError(413, "payload_too_large");
    const bytes = new Uint8Array(data);
    const isPNG = bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47;
    const isJPEG = bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
    if ((contentType === "image/png" && !isPNG) || (contentType === "image/jpeg" && !isJPEG)) {
      throw new HttpError(400, "invalid_request", "the bytes are not that image type");
    }
    await this.ctx.storage.put(`art:${artworkID}`, { contentType, data } satisfies StoredArtwork);
    const index = ((await this.ctx.storage.get<string[]>("artIndex")) ?? []).filter((id) => id !== artworkID);
    index.push(artworkID);
    while (index.length > ARTWORK_KEEP) await this.ctx.storage.delete(`art:${index.shift()!}`);
    await this.ctx.storage.put("artIndex", index);
    this.releaseArtworkWaiters(artworkID);
    return json(201, { artworkID, contentType, byteCount: data.byteLength });
  }

  /** True while the Mac has been asked for this artwork and could still upload it. */
  private artworkUploadPending(artworkID: string): boolean {
    const asked = this.requested.get(artworkID);
    return asked !== undefined && Date.now() - asked < ARTWORK_PENDING_MS && this.macSocket() !== undefined;
  }

  /** Resolves when the upload lands, the Mac says it can't, or `ms` passes. */
  private waitForArtwork(artworkID: string, ms: number): Promise<void> {
    return new Promise((resolve) => {
      const waiters = this.artworkWaiters.get(artworkID) ?? new Set<() => void>();
      this.artworkWaiters.set(artworkID, waiters);
      const finish = () => {
        clearTimeout(timer);
        waiters.delete(finish);
        if (waiters.size === 0 && this.artworkWaiters.get(artworkID) === waiters) this.artworkWaiters.delete(artworkID);
        resolve();
      };
      const timer = setTimeout(finish, ms);
      waiters.add(finish);
    });
  }

  private releaseArtworkWaiters(artworkID: string): void {
    const waiters = this.artworkWaiters.get(artworkID);
    if (!waiters) return;
    this.artworkWaiters.delete(artworkID);
    for (const finish of [...waiters]) finish();
  }

  private async getArtwork(request: Request, url: URL, record: PairingRecord, artworkID: string): Promise<Response> {
    let allowed = await verifySignature(record.artworkKey, artworkID, url.searchParams.get("sig"));
    if (!allowed) {
      const token = bearer(request);
      allowed = !!token && parseToken(token)?.kind === "phone" && sameHash(await sha256Hex(token), record.phoneTokenHash);
    }
    if (!allowed) throw new HttpError(401, "unauthorized");
    let art = await this.ctx.storage.get<StoredArtwork>(`art:${artworkID}`);
    if (!art && this.artworkUploadPending(artworkID)) {
      await this.waitForArtwork(artworkID, ARTWORK_UPLOAD_WAIT_MS);
      art = await this.ctx.storage.get<StoredArtwork>(`art:${artworkID}`);
    }
    if (!art) throw new HttpError(404, "not_found");
    return new Response(art.data, {
      headers: {
        "Content-Type": art.contentType,
        "Cache-Control": "private, max-age=31536000, immutable",
        "X-Content-Type-Options": "nosniff",
        "X-Protocol-Version": String(PROTOCOL_VERSION),
      },
    });
  }

  // MARK: Timers

  async alarm(): Promise<void> {
    const now = Date.now();
    const session = await this.ctx.storage.get<Session>("session");
    const disconnectedAt = await this.ctx.storage.get<number>("macDisconnectedAt");
    if (session && disconnectedAt && now - disconnectedAt >= this.disconnectGrace) {
      await this.endSession("mac_disconnected");
    } else if (session?.pausedSince && now - session.pausedSince >= this.pausedTimeout) {
      await this.endSession("paused_too_long");
    }
    const claims = await this.claims();
    let changed = false;
    for (const [id, claim] of Object.entries(claims)) {
      if (claim.expiresAt <= now) {
        delete claims[id];
        changed = true;
      }
    }
    if (changed) await this.ctx.storage.put("claims", claims);
    await this.scheduleAlarm();
  }

  private async scheduleAlarm(): Promise<void> {
    const deadlines: number[] = [];
    const session = await this.ctx.storage.get<Session>("session");
    const disconnectedAt = await this.ctx.storage.get<number>("macDisconnectedAt");
    if (session && disconnectedAt) deadlines.push(disconnectedAt + this.disconnectGrace);
    if (session?.pausedSince) deadlines.push(session.pausedSince + this.pausedTimeout);
    for (const claim of Object.values(await this.claims())) deadlines.push(claim.expiresAt);
    if (deadlines.length === 0) {
      await this.ctx.storage.deleteAlarm();
      return;
    }
    await this.ctx.storage.setAlarm(Math.min(...deadlines));
  }

  // MARK: Helpers

  private async record(): Promise<PairingRecord | undefined> {
    return this.ctx.storage.get<PairingRecord>("record");
  }

  private async claims(): Promise<Record<string, Claim>> {
    return (await this.ctx.storage.get<Record<string, Claim>>("claims")) ?? {};
  }

  private async tokens(): Promise<PushTokens> {
    return (await this.ctx.storage.get<PushTokens>("tokens")) ?? {};
  }

  private macSocket(): WebSocket | undefined {
    return this.ctx.getWebSockets("mac").find((ws) => ws.readyState === WebSocket.OPEN);
  }

  private sendToMac(frame: RelayFrame): void {
    const ws = this.macSocket();
    if (ws) this.send(ws, frame);
  }

  private send(ws: WebSocket, frame: RelayFrame): void {
    try {
      ws.send(JSON.stringify(frame));
    } catch {
      // closing; the Mac resynchronises on reconnect
    }
  }
}

function iso(ms: number): string {
  return new Date(ms).toISOString();
}

/** First 8 characters, for logs. Never applied to secrets. */
function short(id: string): string {
  return id.slice(0, 8);
}
