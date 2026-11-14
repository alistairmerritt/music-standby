import { DurableObject } from "cloudflare:workers";
import { sha256Hex } from "./crypto";
import type { Env } from "./env";

// One instance, named "directory": live pairing codes and rate limits. Codes
// are stored as SHA-256 hashes and consumed by the first claim.

interface CodeEntry {
  pairingID: string;
  expiresAt: number;
}

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
    const storageKey = `rate:${key}:${start}`;
    const count = ((await this.ctx.storage.get<number>(storageKey)) ?? 0) + 1;
    await this.ctx.storage.put(storageKey, count);
    if (count === 1) await this.scheduleCleanup(start + windowMs);
    return count > limit ? Math.ceil((start + windowMs - now) / 1000) : 0;
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

  async alarm(): Promise<void> {
    const now = Date.now();
    const stale: string[] = [];
    for (const [key, value] of await this.ctx.storage.list<unknown>({ prefix: "rate:" })) {
      const start = Number(key.split(":").pop());
      if (start + 3_600_000 < now) stale.push(key);
      void value;
    }
    for (const [key, value] of await this.ctx.storage.list<CodeEntry>({ prefix: "code:" })) {
      if (value.expiresAt <= now) stale.push(key, `pairing:${value.pairingID}`);
    }
    if (stale.length) await this.ctx.storage.delete(stale);
  }
}
