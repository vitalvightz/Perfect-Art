// GET /events: upcoming published events with ticket types and whether each is on sale.
// Public. Never exposes capacity, allocation or how many are left.

import { clientIp, error, guard, json } from "../_shared/http.ts";
import { clientKey } from "../_shared/crypto.ts";
import { allow, rpc } from "../_shared/db.ts";

Deno.serve(async (req) => {
  const blocked = guard(req, ["GET"]);
  if (blocked) return blocked;

  try {
    if (!(await allow(`events:${await clientKey(clientIp(req))}`, 60, 120))) {
      return error(req, 429, "rate_limited", "Too many requests. Wait a minute and try again.");
    }
    const events = await rpc<unknown[]>("public_event_listing");
    return json(req, { events }, 200, { "Cache-Control": "public, max-age=15" });
  } catch (e) {
    console.error("events failed", e instanceof Error ? e.message : e);
    return error(req, 500, "server_error", "Couldn't load events. Try again shortly.");
  }
});
