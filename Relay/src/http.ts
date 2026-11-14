import { PROTOCOL_VERSION } from "./protocol";

export class HttpError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message?: string,
    readonly retryAfter?: number,
  ) {
    super(message ?? code);
  }
}

export function json(status: number, body: unknown, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "X-Protocol-Version": String(PROTOCOL_VERSION), ...headers },
  });
}

export function empty(status = 204): Response {
  return new Response(null, { status, headers: { "X-Protocol-Version": String(PROTOCOL_VERSION) } });
}

export function errorResponse(e: HttpError): Response {
  const error: Record<string, unknown> = { code: e.code };
  if (e.message && e.message !== e.code) error.message = e.message;
  if (e.retryAfter !== undefined) error.retryAfter = e.retryAfter;
  const headers: Record<string, string> = e.retryAfter !== undefined ? { "Retry-After": String(Math.ceil(e.retryAfter)) } : {};
  return json(e.status, { error }, headers);
}

/** Parses a JSON body of at most `limit` bytes. */
export async function readJSON<T>(request: Request, limit = 64 * 1024): Promise<T> {
  const length = Number(request.headers.get("Content-Length") ?? "0");
  if (length > limit) throw new HttpError(413, "payload_too_large");
  const textBody = await request.text();
  if (textBody.length > limit) throw new HttpError(413, "payload_too_large");
  try {
    return JSON.parse(textBody) as T;
  } catch {
    throw new HttpError(400, "invalid_request", "body is not JSON");
  }
}

export function clientIP(request: Request): string {
  return request.headers.get("CF-Connecting-IP") ?? "local";
}
