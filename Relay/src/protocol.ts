// Wire types: the JSON shapes of Shared/StandByProtocol, which is the source
// of truth. docs/relay/API-v1.md is the contract this relay implements.

export const PROTOCOL_VERSION = 1;

export type PlaybackState = "playing" | "paused" | "stopped" | "not_running" | "automation_denied" | "error";

export interface DeviceIdentity {
  id: string;
  name: string;
  kind: string;
  appVersion?: string;
  osVersion?: string;
}

export interface PairedMac {
  id: string;
  name: string;
}

export interface TrackMetadata {
  id: string;
  title: string;
  artist: string;
  album: string;
  duration: number;
  artworkID?: string;
  /** Apple Music catalogue ID, when the Mac can read it. Added 12 November 2026. Not pushed. */
  catalogID?: string;
}

/** A song in Up Next (Shared/StandByProtocol/Track.swift). */
export interface QueuedTrack {
  catalogID?: string;
  title: string;
  artist: string;
  album?: string;
  duration: number;
}

/** A song's place in a library playlist (Shared/StandByProtocol/Playlist.swift). Added 17 November 2026. Passed through. */
export interface PlaylistPlace {
  name: string;
  cloudID?: string;
  count: number;
  index: number;
  shuffled?: boolean;
  /** True when the phone has just added this Apple Music playlist to the library for the Mac. */
  addedToLibrary?: boolean;
}

/** An Apple Music station (Shared/StandByProtocol/Sources.swift). Added 17 November 2026. Passed through. */
export interface StationPlace {
  id: string;
  name: string;
}

/** A song's place in a library album (Shared/StandByProtocol/Album.swift). Added 17 November 2026. Passed through. */
export interface AlbumPlace {
  title: string;
  artist?: string;
  count: number;
  index: number;
  shuffled?: boolean;
  addedToLibrary?: boolean;
}

/** One place Music can play to (Shared/StandByProtocol/Output.swift). */
export interface AudioOutput {
  id: string;
  name: string;
  kind: string;
  isSelected: boolean;
  isAvailable: boolean;
}

export interface PlaybackMessage {
  revision: number;
  state?: PlaybackState;
  isPlaying: boolean;
  elapsedTime: number;
  capturedAt: string;
  track?: TrackMetadata;
  canGoNext: boolean;
  canGoPrevious: boolean;
  listeningSessionID?: string;
  detail?: string;
  /** Music's own output volume, 0 to 1. Added 11 November 2026. */
  volume?: number;
  outputs?: AudioOutput[];
  /** Up Next, at most 25. Added 12 November 2026. Reaches the phone in GET /v1/session; never pushed. */
  upNext?: QueuedTrack[];
  /** Whether the Mac is connected to Music as a remote, for Continue Listening. Passed through. */
  musicConnection?: string;
  /** The library playlist the song plays from, when Up Next is the rest of it. Reaches the phone in GET /v1/session; never pushed. */
  playlist?: PlaylistPlace;
  /** Added 17 November 2026, like `playlist`: the library album the song plays from. */
  album?: AlbumPlace;
  /** Added 17 November 2026: the Mac shuffles its whole library. */
  shuffledLibrary?: boolean;
  /** Added 17 November 2026: Up Next comes from Apple Music outside the library. */
  fromAppleMusic?: boolean;
  /** Added 17 November 2026: Music's repeat, "off", "one" or "all". */
  repeatMode?: string;
  /** Added 17 November 2026: Music's shuffle, with `fromAppleMusic`. */
  shuffled?: boolean;
}

export interface ProtocolError {
  code: string;
  message?: string;
  retryAfter?: number;
}

export interface RemoteCommand {
  id: string;
  kind: string;
  issuedAt?: string;
  /** Seconds, for `seek`. */
  position?: number;
  /** 0 to 1, for `setVolume`. */
  level?: number;
  /** An `AudioOutput.id`, for `selectOutput`. */
  outputID?: string;
  /** Why the phone sent it; `continue_on_phone` on Continue on iPhone's pause. Passed through. */
  reason?: string;
  /** For `playStation`: the phone's playlist, which a Mac connected to Music plays from the song. Passed through. */
  playlist?: PlaylistPlace;
  /** For `playStation` without a playlist: the phone's library album, which the Mac plays on from the song in album order. Passed through. */
  album?: AlbumPlace;
  /** For `playStation`, added 17 November 2026: the phone's Apple Music station, which the Mac plays instead of the song's. Passed through. */
  station?: StationPlace;
  /** For `playStation`, added 17 November 2026: the phone shuffles its whole library. Passed through. */
  shuffledLibrary?: boolean;
  /** For `playStation`, added 17 November 2026: the phone's repeat. Passed through. */
  repeatMode?: string;
  /** For `playStation`, added 19 November 2026: the phone was paused at `position`, so the Mac seeks exactly there. Passed through. */
  positionIsPaused?: boolean;
}

export interface CommandAck {
  commandID: string;
  accepted: boolean;
  revision: number;
  error?: ProtocolError;
}

export interface ArtworkDescriptor {
  artworkID: string;
  contentType: string;
  byteCount: number;
  width?: number;
  height?: number;
}

export interface PairRequest {
  claimID: string;
  phone: DeviceIdentity;
  expiresAt: string;
}

export interface NowPlayingTrack {
  id: string;
  title: string;
  artist: string;
  album: string;
  duration: number;
  artworkID: string;
  artworkURL?: string;
}

export interface NowPlayingAttributes {
  id: string;
  macName: string;
  revision: number;
  isPlaying: boolean;
  elapsedTime: number;
  timestamp: string;
  track?: NowPlayingTrack;
  canGoNext: boolean;
  canGoPrevious: boolean;
  /** `PlaybackMessage.volume`, for the Lock Screen's slider. */
  volume?: number;
}

export type MacFrame =
  | { type: "hello"; protocolVersion: number; device: DeviceIdentity }
  | { type: "state"; message: PlaybackMessage }
  | { type: "ack"; ack: CommandAck }
  | { type: "artwork"; artwork: ArtworkDescriptor }
  | { type: "goodbye"; reason: string }
  | { type: "pair-decision"; claimID: string; approved: boolean }
  | { type: "hand-back-request"; requestID: string; library?: string; remember?: boolean }
  | { type: "error"; error: ProtocolError };

export type RelayFrame =
  | { type: "welcome"; protocolVersion: number }
  | { type: "command"; command: RemoteCommand }
  | { type: "artwork-request"; artworkID: string }
  | { type: "pair-request"; request: PairRequest }
  | { type: "paired"; phone: DeviceIdentity }
  | { type: "revoked"; reason: string }
  | { type: "hand-back-status"; requestID: string; status: string; item?: HandBackLibraryItem }
  | { type: "error"; error: ProtocolError };


/** `state` wins; without it this is the temporary contract (PROTOCOL.md §3). */
export function stateOf(message: PlaybackMessage): PlaybackState {
  if (message.state) return message.state;
  return message.isPlaying ? "playing" : message.track ? "paused" : "stopped";
}

// ---- Validation ---------------------------------------------------------

const text = (v: unknown, max = 512): v is string => typeof v === "string" && v.length > 0 && v.length <= max;

export function isDevice(v: unknown): v is DeviceIdentity {
  const d = v as DeviceIdentity;
  return !!d && text(d.id, 128) && text(d.name, 200) && text(d.kind, 32);
}

export function isPlaybackMessage(v: unknown): v is PlaybackMessage {
  const m = v as PlaybackMessage;
  return (
    !!m &&
    Number.isSafeInteger(m.revision) &&
    typeof m.isPlaying === "boolean" &&
    typeof m.elapsedTime === "number" &&
    text(m.capturedAt, 40) &&
    typeof m.canGoNext === "boolean" &&
    typeof m.canGoPrevious === "boolean"
  );
}

export function isCommand(v: unknown): v is RemoteCommand {
  const c = v as RemoteCommand;
  return (
    !!c &&
    UUID.test(c.id ?? "") &&
    text(c.kind, 32) &&
    (c.position === undefined || Number.isFinite(c.position)) &&
    (c.level === undefined || Number.isFinite(c.level)) &&
    (c.outputID === undefined || text(c.outputID, 256)) &&
    (c.reason === undefined || text(c.reason, 64))
  );
}

/** What a hand-back push carries for the app (API-v1 §14). */
export interface HandBackRequest {
  requestID: string;
  /** ISO-8601. A background push that wakes the app later than this is ignored. */
  expiresAt: string;
  /**
   * What to do with an Apple Music playlist or album that isn't in the
   * library: "ask", "add" or "station" (28 November 2026). Passed on from the
   * Mac's request; absent when the Mac sent none.
   */
  library?: string;
  /** With library "add" or "station": the phone saves it as its setting. */
  remember?: boolean;
}

/** The playlist or album a library question is about (from the phone, for the Mac's dialog). */
export interface HandBackLibraryItem {
  kind: string;
  name: string;
}

export function isHandBackLibraryItem(v: unknown): v is HandBackLibraryItem {
  const i = v as HandBackLibraryItem;
  return !!i && typeof i.kind === "string" && /^[a-z_]{1,16}$/.test(i.kind) && text(i.name, 256);
}

/** A `HandBackLibraryChoice` from the Mac: an open set of short snake_case words. */
export function isLibraryChoice(v: unknown): v is string {
  return typeof v === "string" && /^[a-z_]{1,16}$/.test(v);
}

/** A `HandBackStatus` from the phone: an open set of short snake_case words. */
export function isHandBackStatus(v: unknown): v is string {
  return typeof v === "string" && /^[a-z_]{1,32}$/.test(v);
}

export function isUUID(v: unknown): v is string {
  return typeof v === "string" && UUID.test(v);
}

export function isAck(v: unknown): v is CommandAck {
  const a = v as CommandAck;
  return !!a && UUID.test(a.commandID ?? "") && typeof a.accepted === "boolean" && Number.isSafeInteger(a.revision);
}

export const UUID = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
export const ARTWORK_ID = /^[0-9a-f]{64}$/;
export const HEX_TOKEN = /^[0-9a-fA-F]{16,512}$/;
