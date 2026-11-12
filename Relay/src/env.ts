import type { Directory } from "./directory";
import type { Pairing } from "./pairing";

export interface Env {
  PAIRING: DurableObjectNamespace<Pairing>;
  DIRECTORY: DurableObjectNamespace<Directory>;
  /** "mock" (default) or "apns". */
  PUSH_MODE?: string;
  APNS_ENVIRONMENT?: string;
  APNS_TOPIC?: string;
  /** Secrets, only for PUSH_MODE=apns. Never logged. */
  APNS_KEY_P8?: string;
  APNS_KEY_ID?: string;
  APNS_TEAM_ID?: string;
  /** "1" enables /v1/dev/*. Off for any public deployment. */
  DEV_ENDPOINTS?: string;
  /** Base for artwork URLs; defaults to the origin the Mac connected to. */
  PUBLIC_BASE_URL?: string;
  ACK_TIMEOUT_MS?: string;
  DISCONNECT_GRACE_MS?: string;
  PAUSED_TIMEOUT_MS?: string;
  /** A Mac that plays after this long not playing sends the phone a reminder, if it asked for them. Default 30 minutes. */
  REMIND_AFTER_MS?: string;
  /** Delay of the repeat update that keeps the phone's extension awake for new artwork. Default 700. */
  ARTWORK_FOLLOW_UP_MS?: string;
  ARTWORK_DOWNLOAD_FOLLOW_UP_MS?: string;
  /** Topic for reminder alerts; defaults to APNS_TOPIC without ".push-type.nowplaying". */
  APNS_APP_TOPIC?: string;
  /** Continue from iPhone: how long the background push gets before the notification. Default 5000. */
  HAND_BACK_NOTIFY_MS?: string;
  /** Continue from iPhone: when a request is forgotten. Default 120000. */
  HAND_BACK_EXPIRY_MS?: string;
}

export function directory(env: Env) {
  return env.DIRECTORY.get(env.DIRECTORY.idFromName("directory"));
}

export function pairing(env: Env, pairingID: string) {
  return env.PAIRING.get(env.PAIRING.idFromName(pairingID));
}
