// Tokens, hashing and ticket signing.
//
// Ticket QR codes are "PA1.<ticket id>.<signature>", where the signature is an HMAC-SHA256 of the
// ticket id under TICKET_SIGNING_SECRET. Codes can't be guessed or forged without the secret, and
// can be regenerated at any time, so nothing secret about a ticket is stored in the database.

import { requireEnv } from "./http.ts";

const enc = new TextEncoder();

function b64url(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function fromB64url(s: string): Uint8Array<ArrayBuffer> | null {
  if (!/^[A-Za-z0-9_-]+$/.test(s)) return null;
  const pad = s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4);
  try {
    const bin = atob(pad);
    const out = new Uint8Array(new ArrayBuffer(bin.length));
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  } catch {
    return null;
  }
}

/** 256-bit random token, URL-safe. */
export function randomToken(): string {
  return b64url(crypto.getRandomValues(new Uint8Array(32)));
}

export async function sha256Hex(value: string): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", enc.encode(value)));
  return Array.from(digest, (b) => b.toString(16).padStart(2, "0")).join("");
}

let keyPromise: Promise<CryptoKey> | null = null;
function signingKey(): Promise<CryptoKey> {
  if (!keyPromise) {
    const secret = requireEnv("TICKET_SIGNING_SECRET");
    if (secret.length < 32) throw new Error("TICKET_SIGNING_SECRET must be at least 32 characters");
    keyPromise = crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, [
      "sign",
      "verify",
    ]);
  }
  return keyPromise;
}

async function hmac(label: string, value: string): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.sign("HMAC", await signingKey(), enc.encode(`${label}:${value}`)));
}

const TICKET_RE = /^PA1\.([0-9a-f-]{36})\.([A-Za-z0-9_-]{43})$/;

export async function signTicket(ticketId: string): Promise<string> {
  return `PA1.${ticketId}.${b64url(await hmac("ticket", ticketId))}`;
}

/** Returns the ticket id if the code carries a valid signature, otherwise null. Constant-time. */
export async function verifyTicket(code: string): Promise<string | null> {
  const m = TICKET_RE.exec(code.trim());
  if (!m) return null;
  const sig = fromB64url(m[2]);
  if (!sig) return null;
  const ok = await crypto.subtle.verify("HMAC", await signingKey(), sig, enc.encode(`ticket:${m[1]}`));
  return ok ? m[1] : null;
}

/**
 * The secret in a buyer's private ticket link (tickets.html#<order id>.<token>). Derived from the
 * order id, so it never has to be stored or passed through the payment provider, and the ticket
 * email can include it at any time. The database stores only its SHA-256.
 */
export async function orderLinkToken(orderId: string): Promise<string> {
  return b64url(await hmac("order-link", orderId));
}

/** Keyed hash of the client IP, so raw IPs are never stored. */
export async function clientKey(ip: string): Promise<string> {
  return b64url(await hmac("ip", ip)).slice(0, 22);
}
