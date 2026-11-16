import { DurableObject } from "cloudflare:workers";
import { sha256Hex } from "./crypto";
import type { Env } from "./env";

// One instance, named "directory": live pairing codes and rate limits. Codes
// are stored as SHA-256 hashes and consumed by the first claim. A rate-limit
// count is keyed by IP address, so it's deleted as soon as its window ends:
// the alarm always wakes for the next code or count due to go (privacy
// policy, 16 November 2026).

interface CodeEntry {
  pairingID: string;
  expiresAt: number;
}

/** A rate-limit count. Before 16 November 2026 counts were bare numbers. */
interface RateEntry {
  count: number;
  /** When the window ends and the count is deleted. */
  until: number;
}

/** How long a bare-number count from before 16 November 2026 is kept: the longest window. */
const LEGACY_RATE_KEEP_MS = 60 * 60 * 1000;

export const CODE_TTL_MS = 5 * 60 * 1000;
/** Wrong guesses inside one code lifetime before every live code is killed. */
export const MAX_FAILED_CLAIMS = 5;

export class Directory extends DurableObject<Env> {
  /** Replaces the pairing's previous code. Returns the expiry. */
  async registerCode(pairingID: string, code: string, now = Date.now()): Promise<number> {
    const previous = await this.ctx.storage.get<string>(`pairing:${pairingID}`);
    if (previous) await this.ctx.storage.delete(`code:${previous}`);
    const hash = await sha256Hex(code);
    const expiresAt = now + CODE_TTL_MS;
    await this.ctx.storage.put({ [`code:${hash}`]: { pairingID, expiresAt } satisfies CodeEntry, [`pairing:${pairingID}`]: hash });
    await this.scheduleCleanup(expiresAt);
    return expiresAt;
  }

  /** One-time: the code is gone after this, whether or not it was valid. */
  async consumeCode(code: string, now = Date.now()): Promise<string | null> {
    const hash = await sha256Hex(code);
    const entry = await this.ctx.storage.get<CodeEntry>(`code:${hash}`);
    if (entry) {
      await this.ctx.storage.delete([`code:${hash}`, `pairing:${entry.pairingID}`]);
      if (entry.expiresAt > now) return entry.pairingID;
      return null;
    }
    await this.recordFailure(now);
    return null;
  }

  async removeCodeFor(pairingID: string): Promise<void> {
    const previous = await this.ctx.storage.get<string>(`pairing:${pairingID}`);
    if (previous) await this.ctx.storage.delete([`code:${previous}`, `pairing:${pairingID}`]);
  }

  /**
   * Fixed-window counter. Returns 0 when allowed, or the seconds to wait.
   */
  async hit(key: string, limit: number, windowSeconds: number, now = Date.now()): Promise<number> {
    const windowMs = windowSeconds * 1000;
    const start = Math.floor(now / windowMs) * windowMs;
    const until = start + windowMs;
    const storageKey = `rate:${key}:${start}`;
    const count = rateCount(await this.ctx.storage.get<RateEntry | number>(storageKey)) + 1;
    await this.ctx.storage.put(storageKey, { count, until } satisfies RateEntry);
    if (count === 1) await this.scheduleCleanup(until);
    return count > limit ? Math.ceil((until - now) / 1000) : 0;
  }

  /** Too many wrong codes: kill every live code. Each Mac must make a new one. */
  private async recordFailure(now: number): Promise<void> {
    const recent = ((await this.ctx.storage.get<number[]>("failures")) ?? []).filter((t) => now - t < CODE_TTL_MS);
    recent.push(now);
    if (recent.length >= MAX_FAILED_CLAIMS) {
      const codes = await this.ctx.storage.list({ prefix: "code:" });
      const pairings = await this.ctx.storage.list({ prefix: "pairing:" });
      await this.ctx.storage.delete([...codes.keys(), ...pairings.keys()]);
      await this.ctx.storage.put("failures", []);
      console.log("directory: too many wrong pairing codes; all live codes cleared");
      return;
    }
    await this.ctx.storage.put("failures", recent);
  }

  private async scheduleCleanup(at: number): Promise<void> {
    const current = await this.ctx.storage.getAlarm();
    if (current === null || current > at) await this.ctx.storage.setAlarm(at + 1000);
  }

  /** Deletes every count and code whose time is up, then wakes again for the next. */
  async alarm(): Promise<void> {
    const now = Date.now();
    const stale: string[] = [];
    const later: number[] = [];
    for (const [key, value] of await this.ctx.storage.list<RateEntry | number>({ prefix: "rate:" })) {
      // An IPv6 address has colons of its own: the window's start is the last field.
      const until = typeof value === "number" ? Number(key.split(":").pop()) + LEGACY_RATE_KEEP_MS : value.until;
      if (until <= now) stale.push(key);
      else later.push(until);
    }
    for (const [key, value] of await this.ctx.storage.list<CodeEntry>({ prefix: "code:" })) {
      if (value.expiresAt <= now) stale.push(key, `pairing:${value.pairingID}`);
      else later.push(value.expiresAt);
    }
    // Storage deletes at most 128 keys at a time.
    for (let i = 0; i < stale.length; i += 128) await this.ctx.storage.delete(stale.slice(i, i + 128));
    if (later.length) await this.ctx.storage.setAlarm(Math.min(...later) + 1000);
  }
}

function rateCount(entry: RateEntry | number | undefined): number {
  if (entry === undefined) return 0;
  return typeof entry === "number" ? entry : entry.count;
}
