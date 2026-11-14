// Credentials, codes and signatures. Secrets are generated with the Web
// Crypto CSPRNG, stored only as SHA-256 hashes, and compared in constant time.

export type TokenKind = "mac" | "phone" | "claim";

const TOKEN = /^msb1\.(mac|phone|claim)\.([0-9a-f]{32})\.([A-Za-z0-9_-]{43})$/;

export function randomBytes(n: number): Uint8Array {
  return crypto.getRandomValues(new Uint8Array(n));
}

export function hex(bytes: ArrayBuffer | Uint8Array): string {
  return [...new Uint8Array(bytes)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export function base64url(bytes: ArrayBuffer | Uint8Array): string {
  let s = "";
  for (const b of new Uint8Array(bytes)) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** 128-bit identifier as 32 lowercase hex characters. */
export function newID(): string {
  return hex(randomBytes(16));
}

/** `msb1.<kind>.<id>.<32 random bytes, base64url>`. */
export function newToken(kind: TokenKind, id: string): string {
  return `msb1.${kind}.${id}.${base64url(randomBytes(32))}`;
}

export function parseToken(token: string | null | undefined): { kind: TokenKind; id: string } | null {
  const m = token ? TOKEN.exec(token) : null;
  return m ? { kind: m[1] as TokenKind, id: m[2] } : null;
}

export function bearer(request: Request): string | null {
  const header = request.headers.get("Authorization") ?? "";
  return header.startsWith("Bearer ") ? header.slice(7).trim() : null;
}

export async function sha256Hex(value: string): Promise<string> {
  return hex(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)));
}

/** Constant-time comparison of two hex digests. */
export function sameHash(a: string | undefined, b: string | undefined): boolean {
  if (!a || !b || a.length !== b.length) return false;
  const enc = new TextEncoder();
  return crypto.subtle.timingSafeEqual(enc.encode(a), enc.encode(b));
}

/** Six digits, uniform over 000000–999999 (rejection sampling). */
export function newPairingCode(): string {
  const limit = Math.floor(0x1_0000_0000 / 1_000_000) * 1_000_000;
  for (;;) {
    const n = crypto.getRandomValues(new Uint32Array(1))[0];
    if (n < limit) return String(n % 1_000_000).padStart(6, "0");
  }
}

/** base64url of the first 16 bytes of HMAC-SHA256(keyHex, message). */
export async function sign(keyHex: string, message: string): Promise<string> {
  const keyBytes = new Uint8Array(keyHex.match(/../g)!.map((h) => parseInt(h, 16)));
  const key = await crypto.subtle.importKey("raw", keyBytes, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(message));
  return base64url(new Uint8Array(mac).slice(0, 16));
}

export async function verifySignature(keyHex: string, message: string, signature: string | null): Promise<boolean> {
  if (!signature) return false;
  const expected = await sign(keyHex, message);
  const enc = new TextEncoder();
  const a = enc.encode(expected);
  const b = enc.encode(signature);
  return a.length === b.length && crypto.subtle.timingSafeEqual(a, b);
}
