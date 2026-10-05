// Service-role database access. Only ever used inside Edge Functions; the key never reaches a browser.

import { createClient } from "npm:@supabase/supabase-js@2.117.2";
import { requireEnv } from "./http.ts";

export const db = createClient(requireEnv("SUPABASE_URL"), requireEnv("SUPABASE_SERVICE_ROLE_KEY"), {
  auth: { persistSession: false, autoRefreshToken: false },
});

export class RpcError extends Error {
  constructor(message: string, readonly code?: string) {
    super(message);
  }
}

export async function rpc<T>(fn: string, args: Record<string, unknown> = {}): Promise<T> {
  const { data, error } = await db.rpc(fn, args);
  if (error) throw new RpcError(error.message, error.code);
  return data as T;
}

/** Fixed-window rate limit. Returns true when the request may go ahead. */
export function allow(key: string, windowSeconds: number, max: number): Promise<boolean> {
  return rpc<boolean>("hit_rate_limit", { p_key: key, p_window_seconds: windowSeconds, p_max: max });
}

/**
 * Per-client limit plus a global ceiling for the endpoint. The global ceiling still holds if a
 * caller fakes a new IP on every request. Both are counted on every call.
 */
export async function allowClient(
  endpoint: string,
  clientKey: string,
  perClient: [windowSeconds: number, max: number],
  global: [windowSeconds: number, max: number],
): Promise<boolean> {
  const [clientOk, globalOk] = await Promise.all([
    allow(`${endpoint}:${clientKey}`, perClient[0], perClient[1]),
    allow(`${endpoint}:global`, global[0], global[1]),
  ]);
  return clientOk && globalOk;
}
