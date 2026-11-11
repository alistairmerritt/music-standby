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
}

export type MacFrame =
  | { type: "hello"; protocolVersion: number; device: DeviceIdentity }
  | { type: "state"; message: PlaybackMessage }
  | { type: "ack"; ack: CommandAck }
  | { type: "artwork"; artwork: ArtworkDescriptor }
  | { type: "goodbye"; reason: string }
  | { type: "pair-decision"; claimID: string; approved: boolean }
  | { type: "error"; error: ProtocolError };

export type RelayFrame =
  | { type: "welcome"; protocolVersion: number }
  | { type: "command"; command: RemoteCommand }
  | { type: "artwork-request"; artworkID: string }
  | { type: "pair-request"; request: PairRequest }
  | { type: "paired"; phone: DeviceIdentity }
  | { type: "revoked"; reason: string }
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
  return !!c && UUID.test(c.id ?? "") && text(c.kind, 32);
}

export function isAck(v: unknown): v is CommandAck {
  const a = v as CommandAck;
  return !!a && UUID.test(a.commandID ?? "") && typeof a.accepted === "boolean" && Number.isSafeInteger(a.revision);
}

export const UUID = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
export const ARTWORK_ID = /^[0-9a-f]{64}$/;
export const HEX_TOKEN = /^[0-9a-fA-F]{16,512}$/;
