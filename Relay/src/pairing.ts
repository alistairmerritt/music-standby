import { DurableObject } from "cloudflare:workers";
import { bearer, hex, newToken, parseToken, randomBytes, sameHash, sha256Hex, sign, verifySignature, newPairingCode } from "./crypto";
import { directory, type Env } from "./env";
import { HttpError, empty, errorResponse, json, readJSON } from "./http";
import {
  ARTWORK_ID,
  HEX_TOKEN,
  PROTOCOL_VERSION,
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
  type TrackMetadata,
  isHandBackStatus,
  isUUID,
} from "./protocol";
import {
  APNsPushSender,
  MockPushSender,
  REMINDER_ID,
  makeHandBackAlert,
  makeHandBackWake,
  makePush,
  makeReminder,
  tokenIsDead,
  type AlertPush,
  type APNsEnvironment,
  type BackgroundPush,
  type ProviderToken,
  type Push,
  type PushEvent,
  type PushResult,
  type PushSender,
} from "./push";

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

/**
 * One Now Playing session lasts as long as the pairing. iOS 27.2 shows a
 * session only once the app has asked for it while open, and a session started
 * by a push stays hidden. So Music stopping or quitting, a new listening
 * session, a long pause, or the Mac going away all update this session, with
 * the last track paused, rather than ending it for a replacement no one sees
 * (seen on an iPhone, 11 November 2026).
 */
interface Session {
  sessionID: string;
  listeningSessionID?: string;
  startedAt: number;
  /** Revision of the last state actually pushed. */
  pushedRevision: number;
  pausedSince?: number;
  /** Shown while the Mac reports no track, so the player isn't blanked. */
  lastTrack?: TrackMetadata;
  /** The Mac went away and the phone was told it paused; its next state is pushed whatever its revision. */
  macAway?: boolean;
  /** The artwork the phone was last pushed, to know when an update brings new artwork. */
  pushedArtworkID?: string;
}

interface PushTokens {
  start?: string;
  session?: { sessionID: string; token: string };
  /** The app's ordinary push token; present only while the phone wants reminders. */
  alert?: string;
  /** The same kind of token, whatever the reminder setting: for Continue from iPhone (API-v1 §14). */
  device?: string;
}

/** A Continue from iPhone request the relay is working on (API-v1 §14). */
interface HandBack {
  requestID: string;
  askedAt: number;
  /** When to show the notification if the phone hasn't answered the background push. */
  notifyAt: number;
  /** When the request is forgotten. */
  expiresAt: number;
  /** The phone has sent a status, so no notification is needed. */
  answered: boolean;
  notified: boolean;
}

interface StoredArtwork {
  contentType: string;
  data: ArrayBuffer;
}

interface RecordedPush {
  at: string;
  event: PushEvent | "reminder" | "hand-back" | "hand-back-alert";
  sessionID: string;
  status: number;
  payload: Push["payload"] | AlertPush["payload"] | BackgroundPush["payload"];
  collapseID?: string;
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
/**
 * iOS takes an update's artwork from the Now Playing extension about 1.07 s
 * after the update, but suspends the extension about 1.0 s after it, and
 * doesn't wake it for artwork. So artwork in the last update of a burst never
 * showed (seen on an iPhone, 11 Nov 2026). The same update pushed again this
 * long after keeps the extension awake past that moment; it has cached the
 * image by then.
 */
const ARTWORK_FOLLOW_UP_MS = 700;
/**
 * An extension woken after minutes asleep can take longer than that to
 * download the image: on the first TestFlight build (12 Nov 2026), the first
 * song after the phone had slept got its title but not its artwork, and later
 * songs got both. So when the phone downloads the artwork of the update it was
 * last pushed, that update goes again this long after the download, by when
 * the image is cached. Once per artwork; a download before the update is
 * pushed doesn't count.
 */
const ARTWORK_DOWNLOAD_FOLLOW_UP_MS = 1000;
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
  /** The artwork a download follow-up is waiting or was sent for; see ARTWORK_DOWNLOAD_FOLLOW_UP_MS. */
  private downloadFollowUp?: string;

  private get ackTimeout(): number {
    return Number(this.env.ACK_TIMEOUT_MS ?? 1200);
  }
  private get disconnectGrace(): number {
    return Number(this.env.DISCONNECT_GRACE_MS ?? 60_000);
  }
  /** 0, the default, keeps a paused session for good; see `Session`. */
  private get pausedTimeout(): number {
    return Number(this.env.PAUSED_TIMEOUT_MS ?? 0);
  }
  private get remindAfter(): number {
    return Number(this.env.REMIND_AFTER_MS ?? 30 * 60_000);
  }
  /** How long a background hand-back push gets before the notification. */
  private get handBackNotifyAfter(): number {
    return Number(this.env.HAND_BACK_NOTIFY_MS ?? 5_000);
  }
  private get handBackLifetime(): number {
    return Number(this.env.HAND_BACK_EXPIRY_MS ?? 2 * 60_000);
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
    if (method === "PUT" && path === "/v1/tokens/alert") return this.putAlertToken(request);
    if (method === "DELETE" && path === "/v1/tokens/alert") return this.deleteAlertToken();
    if (method === "PUT" && path === "/v1/tokens/device") return this.putDeviceToken(request);
    if (method === "POST" && path === "/v1/hand-back/status") return this.handBackStatus(request);
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
        await this.markMacAway("goodbye");
        return;
      case "pair-decision":
        return this.decide(String(frame.claimID), frame.approved === true);
      case "hand-back-request":
        return this.handBackRequested(frame.requestID);
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
    const session = await this.ctx.storage.get<Session>("session");
    if (!session) {
      if (state !== "playing") return;
      // A session the phone dismissed stays dismissed for that listening session.
      const dismissed = await this.ctx.storage.get<string>("dismissed");
      if (dismissed && message.listeningSessionID === dismissed) return;
      await this.ctx.storage.delete("dismissed");
      await this.startSession(message);
      return;
    }
    // Stopped, quit or a new listening session: the same session, updated.
    const restarted = state === "playing" && session.pausedSince !== undefined && Date.now() - session.pausedSince >= this.remindAfter;
    session.listeningSessionID = message.listeningSessionID ?? session.listeningSessionID;
    session.pausedSince = state === "playing" ? undefined : (session.pausedSince ?? Date.now());
    if (message.track) session.lastTrack = message.track;
    const wasAway = session.macAway === true;
    delete session.macAway;
    await this.ctx.storage.put("session", session);
    if (wasAway || message.revision > session.pushedRevision) await this.pushUpdate(session, message);
    if (restarted) await this.remind();
    await this.scheduleAlarm();
  }

  /**
   * Music started after a break. The player may have been dismissed, and only
   * opening the app brings it back, so a phone that asked gets a notification.
   * Sent blind: nothing tells the relay whether the player is showing.
   */
  private async remind(): Promise<void> {
    const tokens = await this.tokens();
    const record = await this.record();
    if (!tokens.alert || !record) return;
    const result = await this.pushSender().sendAlert(makeReminder(tokens.alert, record.mac.name));
    console.log(`pairing: reminder → ${result.status}${result.reason ? ` ${result.reason}` : ""}`);
    if (tokenIsDead(result)) {
      delete tokens.alert;
      await this.ctx.storage.put("tokens", tokens);
    }
  }

  /**
   * The Mac quit the companion or stayed disconnected past the grace period.
   * A playing session is pushed as paused at its extrapolated position, so the
   * phone doesn't show music running that may have stopped. Same revision: the
   * phone accepts an equal one, and the Mac's next state is pushed regardless.
   */
  private async markMacAway(reason: string): Promise<void> {
    const session = await this.ctx.storage.get<Session>("session");
    const playback = await this.ctx.storage.get<PlaybackMessage>("playback");
    if (!session || session.macAway) return;
    session.macAway = true;
    await this.ctx.storage.put("session", session);
    console.log(`session ${short(session.sessionID)}: Mac away (${reason})`);
    if (!playback || stateOf(playback) !== "playing") return;
    const now = Date.now();
    const ran = Math.max(0, (now - Date.parse(playback.capturedAt)) / 1000);
    const duration = playback.track?.duration;
    const elapsed = playback.elapsedTime + (Number.isFinite(ran) ? ran : 0);
    const paused: PlaybackMessage = {
      ...playback,
      state: "paused",
      isPlaying: false,
      elapsedTime: duration && duration > 0 ? Math.min(elapsed, duration) : elapsed,
      capturedAt: new Date(now).toISOString(),
    };
    await this.ctx.storage.put("playback", paused);
    session.pausedSince = now;
    await this.ctx.storage.put("session", session);
    await this.pushUpdate(session, paused);
  }

  private async startSession(message: PlaybackMessage): Promise<void> {
    const session: Session = {
      sessionID: crypto.randomUUID(),
      listeningSessionID: message.listeningSessionID,
      startedAt: Date.now(),
      pushedRevision: message.revision,
    };
    if (message.track) session.lastTrack = message.track;
    await this.ctx.storage.put("session", session);
    console.log(`session ${short(session.sessionID)}: started`);
    const tokens = await this.tokens();
    if (tokens.start) {
      await this.push("start", tokens.start, await this.attributes(session, message));
    } else {
      console.log(`session ${short(session.sessionID)}: no push-to-start token; the phone must foreground to see it`);
    }
    // A session started by push stays hidden until the app is opened.
    await this.remind();
    await this.scheduleAlarm();
  }

  private async pushUpdate(session: Session, message: PlaybackMessage): Promise<void> {
    const tokens = await this.tokens();
    const token = tokens.session?.sessionID === session.sessionID ? tokens.session.token : undefined;
    if (!token) return; // sent when the extension registers its token
    const attributes = await this.attributes(session, message);
    const ok = await this.push("update", token, attributes);
    if (ok) {
      session.pushedRevision = message.revision;
      const artwork = attributes.track?.artworkID || undefined;
      const newArtwork = artwork !== undefined && artwork !== session.pushedArtworkID;
      session.pushedArtworkID = artwork;
      await this.ctx.storage.put("session", session);
      if (newArtwork) void this.followUp(session.sessionID, message.revision, token, attributes);
    }
  }

  /** The same update again, unless something newer has gone out since. */
  private async followUp(sessionID: string, revision: number, token: string, attributes: NowPlayingAttributes): Promise<void> {
    await new Promise((resolve) => setTimeout(resolve, Number(this.env.ARTWORK_FOLLOW_UP_MS ?? ARTWORK_FOLLOW_UP_MS)));
    const session = await this.ctx.storage.get<Session>("session");
    const tokens = await this.tokens();
    if (session?.sessionID !== sessionID || session.pushedRevision !== revision || tokens.session?.token !== token) return;
    await this.push("update", token, attributes);
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
    const track = message.track ?? session.lastTrack;
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
      ...(typeof message.volume === "number" ? { volume: message.volume } : {}),
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

  /** The phone turned reminders on; its ordinary APNs device token. */
  private async putAlertToken(request: Request): Promise<Response> {
    const body = await readJSON<{ token?: string }>(request);
    if (!body?.token || !HEX_TOKEN.test(body.token)) throw new HttpError(400, "invalid_request", "token must be hex");
    const tokens = await this.tokens();
    tokens.alert = body.token.toLowerCase();
    await this.ctx.storage.put("tokens", tokens);
    return empty();
  }

  /** The app's device token, for Continue from iPhone; sent whatever the reminder setting. */
  private async putDeviceToken(request: Request): Promise<Response> {
    const body = await readJSON<{ token?: string }>(request);
    if (!body?.token || !HEX_TOKEN.test(body.token)) throw new HttpError(400, "invalid_request", "token must be hex");
    const tokens = await this.tokens();
    tokens.device = body.token.toLowerCase();
    await this.ctx.storage.put("tokens", tokens);
    return empty();
  }

  private async deleteAlertToken(): Promise<Response> {
    const tokens = await this.tokens();
    if (tokens.alert) {
      delete tokens.alert;
      await this.ctx.storage.put("tokens", tokens);
    }
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
          appTopic: env.APNS_APP_TOPIC,
          environment: env.APNS_ENVIRONMENT === "production" ? "production" : "development",
        },
        undefined,
        {
          get: () => this.ctx.storage.get<ProviderToken>("apnsProviderToken"),
          put: (token) => (token ? this.ctx.storage.put("apnsProviderToken", token) : this.ctx.storage.delete("apnsProviderToken").then(() => {})),
        },
        {
          get: () => this.ctx.storage.get<APNsEnvironment>("apnsEnvironment"),
          put: (environment) => this.ctx.storage.put("apnsEnvironment", environment),
        },
      );
      return this.apns;
    }
    return new MockPushSender(async (push) => {
      const pushes = (await this.ctx.storage.get<RecordedPush[]>("pushes")) ?? [];
      const at = iso(Date.now());
      pushes.push(
        "collapseID" in push
          ? { at, event: push.collapseID === REMINDER_ID ? "reminder" : "hand-back-alert", sessionID: "", status: 200, payload: push.payload, collapseID: push.collapseID }
          : "event" in push
            ? { at, event: push.event, sessionID: push.sessionID, status: 200, payload: push.payload }
            : { at, event: "hand-back", sessionID: "", status: 200, payload: push.payload },
      );
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
    void this.followUpAfterDownload(artworkID);
    return new Response(art.data, {
      headers: {
        "Content-Type": art.contentType,
        "Cache-Control": "private, max-age=31536000, immutable",
        "X-Content-Type-Options": "nosniff",
        "X-Protocol-Version": String(PROTOCOL_VERSION),
      },
    });
  }

  /** The last pushed update again, once the phone has its artwork; see ARTWORK_DOWNLOAD_FOLLOW_UP_MS. */
  private async followUpAfterDownload(artworkID: string): Promise<void> {
    if (this.downloadFollowUp === artworkID) return;
    this.downloadFollowUp = artworkID;
    await new Promise((resolve) => setTimeout(resolve, Number(this.env.ARTWORK_DOWNLOAD_FOLLOW_UP_MS ?? ARTWORK_DOWNLOAD_FOLLOW_UP_MS)));
    const session = await this.ctx.storage.get<Session>("session");
    const playback = await this.ctx.storage.get<PlaybackMessage>("playback");
    const tokens = await this.tokens();
    const token = session && tokens.session?.sessionID === session.sessionID ? tokens.session.token : undefined;
    if (!session || !token || !playback || session.pushedArtworkID !== artworkID || playback.revision !== session.pushedRevision) {
      // Not (or no longer) the artwork on the phone: a later download may still count.
      if (this.downloadFollowUp === artworkID) this.downloadFollowUp = undefined;
      return;
    }
    await this.push("update", token, await this.attributes(session, playback));
  }

  // MARK: Continue from iPhone (API-v1 §14)

  /**
   * The Mac asks for the phone's music. The phone's app is woken by a
   * background push; if it hasn't said anything within HAND_BACK_NOTIFY_MS,
   * the alarm shows a notification instead. A new request replaces the last.
   */
  private async handBackRequested(requestID: unknown): Promise<void> {
    if (!isUUID(requestID)) {
      this.sendToMac({ type: "error", error: { code: "invalid_frame", message: "hand-back-request needs a UUID requestID" } });
      return;
    }
    const now = Date.now();
    const handBack: HandBack = {
      requestID,
      askedAt: now,
      notifyAt: now + this.handBackNotifyAfter,
      expiresAt: now + this.handBackLifetime,
      answered: false,
      notified: false,
    };
    const token = (await this.tokens()).device;
    if (!token) {
      console.log(`hand-back ${short(requestID)}: no device token`);
      this.sendToMac({ type: "hand-back-status", requestID, status: "unreachable" });
      return;
    }
    await this.ctx.storage.put("handBack", handBack);
    const result = await this.pushSender().sendBackground(makeHandBackWake(token, { requestID, expiresAt: iso(handBack.expiresAt) }));
    console.log(`hand-back ${short(requestID)}: background push → ${result.status}${result.reason ? ` ${result.reason}` : ""}`);
    if (await this.dropDeadDeviceToken(token, result)) {
      await this.ctx.storage.delete("handBack");
      this.sendToMac({ type: "hand-back-status", requestID, status: "unreachable" });
      return;
    }
    if (result.status >= 200 && result.status < 300) {
      this.sendToMac({ type: "hand-back-status", requestID, status: "asked" });
    } else {
      // APNs took no background push: show the notification now.
      handBack.notifyAt = now;
      await this.ctx.storage.put("handBack", handBack);
    }
    await this.scheduleAlarm();
    if (handBack.notifyAt <= now) await this.notifyHandBack();
  }

  /** The phone's progress. Any status means it's awake: no notification needed. */
  private async handBackStatus(request: Request): Promise<Response> {
    const body = await readJSON<{ requestID?: string; status?: string }>(request);
    if (!isUUID(body?.requestID) || !isHandBackStatus(body?.status)) {
      throw new HttpError(400, "invalid_request", "requestID must be a UUID and status a short word");
    }
    const handBack = await this.ctx.storage.get<HandBack>("handBack");
    if (!handBack || handBack.requestID.toLowerCase() !== body.requestID.toLowerCase()) return empty();
    if (!handBack.answered) {
      handBack.answered = true;
      await this.ctx.storage.put("handBack", handBack);
      await this.scheduleAlarm();
    }
    console.log(`hand-back ${short(handBack.requestID)}: phone says ${body.status}`);
    this.sendToMac({ type: "hand-back-status", requestID: handBack.requestID, status: body.status });
    return empty();
  }

  /** The background push got no answer in time: a notification whose tap hands back. */
  private async notifyHandBack(): Promise<void> {
    const handBack = await this.ctx.storage.get<HandBack>("handBack");
    if (!handBack || handBack.answered || handBack.notified) return;
    const token = (await this.tokens()).device;
    const record = await this.record();
    handBack.notified = true;
    await this.ctx.storage.put("handBack", handBack);
    if (!token || !record) {
      this.sendToMac({ type: "hand-back-status", requestID: handBack.requestID, status: "unreachable" });
      return;
    }
    const request = { requestID: handBack.requestID, expiresAt: iso(handBack.expiresAt) };
    const result = await this.pushSender().sendAlert(makeHandBackAlert(token, record.mac.name, request));
    console.log(`hand-back ${short(handBack.requestID)}: notification → ${result.status}${result.reason ? ` ${result.reason}` : ""}`);
    const delivered = result.status >= 200 && result.status < 300;
    if (!delivered) await this.dropDeadDeviceToken(token, result);
    this.sendToMac({ type: "hand-back-status", requestID: handBack.requestID, status: delivered ? "notified" : "unreachable" });
  }

  /** True, having forgotten it, when APNs says the device token is dead. */
  private async dropDeadDeviceToken(token: string, result: PushResult): Promise<boolean> {
    if (!tokenIsDead(result)) return false;
    const tokens = await this.tokens();
    if (tokens.device === token) {
      delete tokens.device;
      await this.ctx.storage.put("tokens", tokens);
    }
    return true;
  }

  // MARK: Timers

  async alarm(): Promise<void> {
    const now = Date.now();
    const session = await this.ctx.storage.get<Session>("session");
    const disconnectedAt = await this.ctx.storage.get<number>("macDisconnectedAt");
    if (session && !session.macAway && disconnectedAt && now - disconnectedAt >= this.disconnectGrace) {
      await this.markMacAway("disconnected");
    } else if (this.pausedTimeout > 0 && session?.pausedSince && now - session.pausedSince >= this.pausedTimeout) {
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
    const handBack = await this.ctx.storage.get<HandBack>("handBack");
    if (handBack && now >= handBack.expiresAt) {
      await this.ctx.storage.delete("handBack");
    } else if (handBack && !handBack.answered && !handBack.notified && now >= handBack.notifyAt) {
      await this.notifyHandBack();
    }
    await this.scheduleAlarm();
  }

  private async scheduleAlarm(): Promise<void> {
    const deadlines: number[] = [];
    const session = await this.ctx.storage.get<Session>("session");
    const disconnectedAt = await this.ctx.storage.get<number>("macDisconnectedAt");
    if (session && !session.macAway && disconnectedAt) deadlines.push(disconnectedAt + this.disconnectGrace);
    if (this.pausedTimeout > 0 && session?.pausedSince) deadlines.push(session.pausedSince + this.pausedTimeout);
    for (const claim of Object.values(await this.claims())) deadlines.push(claim.expiresAt);
    const handBack = await this.ctx.storage.get<HandBack>("handBack");
    if (handBack) deadlines.push(handBack.answered || handBack.notified ? handBack.expiresAt : handBack.notifyAt);
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
