// Shared HTTP helpers: CORS, JSON responses, client IP.

const allowedOrigins = (Deno.env.get("ALLOWED_ORIGINS") ?? "")
  .split(",")
  .map((o) => o.trim())
  .filter(Boolean);

export function originAllowed(req: Request): boolean {
  const origin = req.headers.get("Origin");
  // Requests without an Origin header (server-to-server, curl) aren't browser cross-site requests.
  return origin === null || allowedOrigins.includes(origin);
}

function baseHeaders(req: Request): Headers {
  const h = new Headers({
    "Content-Type": "application/json; charset=utf-8",
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
    "Vary": "Origin",
  });
  const origin = req.headers.get("Origin");
  if (origin && allowedOrigins.includes(origin)) {
    h.set("Access-Control-Allow-Origin", origin);
    h.set("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
    h.set("Access-Control-Allow-Headers", "authorization, content-type, apikey, x-client-info");
    h.set("Access-Control-Max-Age", "600");
  }
  return h;
}

export function json(req: Request, body: unknown, status = 200, extra: Record<string, string> = {}): Response {
  const headers = baseHeaders(req);
  for (const [k, v] of Object.entries(extra)) headers.set(k, v);
  return new Response(JSON.stringify(body), { status, headers });
}

export function error(req: Request, status: number, code: string, message: string): Response {
  return json(req, { error: code, message }, status);
}

/** Handles CORS preflight and rejects browser requests from origins not on the allow-list. */
export function guard(req: Request, methods: string[]): Response | null {
  if (req.method === "OPTIONS") {
    return originAllowed(req) ? new Response(null, { status: 204, headers: baseHeaders(req) }) : new Response(null, { status: 403 });
  }
  if (!originAllowed(req)) return error(req, 403, "origin_not_allowed", "This site isn't allowed to call the ticket service.");
  if (!methods.includes(req.method)) return error(req, 405, "method_not_allowed", `Use ${methods.join(" or ")}.`);
  return null;
}

/** Reads a small JSON object body, giving up as soon as it passes maxBytes (counted in bytes). */
export async function readJson(req: Request, maxBytes = 4096): Promise<Record<string, unknown> | null> {
  if (Number(req.headers.get("content-length") ?? 0) > maxBytes) return null;
  const reader = req.body?.getReader();
  if (!reader) return null;
  const decoder = new TextDecoder();
  let text = "";
  let size = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > maxBytes) {
      await reader.cancel().catch(() => {});
      return null;
    }
    text += decoder.decode(value, { stream: true });
  }
  text += decoder.decode();
  try {
    const value = JSON.parse(text);
    return value && typeof value === "object" && !Array.isArray(value) ? value : null;
  } catch {
    return null;
  }
}

/**
 * Best-effort client IP for per-IP rate limits. cf-connecting-ip is set by Cloudflare, which
 * overwrites any value the client sends. The fallbacks may be client-controlled, which is why every
 * public endpoint also has a global limit that can't be dodged by faking addresses.
 */
export function clientIp(req: Request): string {
  const fwd = req.headers.get("x-forwarded-for");
  return (req.headers.get("cf-connecting-ip") ?? req.headers.get("x-real-ip") ?? fwd?.split(",")[0] ?? "unknown").trim();
}

export const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function requireEnv(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`Missing required secret ${name}`);
  return value;
}
