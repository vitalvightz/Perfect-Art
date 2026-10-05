// POST /check-in  { code, event_id }   Authorization: Bearer <staff member's access token>
// Door scanning. Identity comes from the verified Supabase session, never from the request body.
// The database confirms the user is staff and checks the ticket in atomically.

import { error, guard, json, readJson, UUID_RE } from "../_shared/http.ts";
import { verifyTicket } from "../_shared/crypto.ts";
import { allow, db, rpc, RpcError } from "../_shared/db.ts";

Deno.serve(async (req) => {
  const blocked = guard(req, ["POST"]);
  if (blocked) return blocked;

  const jwt = req.headers.get("Authorization")?.replace(/^Bearer\s+/i, "") ?? "";
  const { data: auth } = jwt ? await db.auth.getUser(jwt) : { data: { user: null } };
  const userId = auth?.user?.id;
  if (!userId) return error(req, 401, "not_signed_in", "Sign in with your staff account.");

  const body = await readJson(req);
  const code = typeof body?.code === "string" ? body.code.slice(0, 200) : "";
  const eventId = body?.event_id;
  if (typeof eventId !== "string" || !UUID_RE.test(eventId)) {
    return error(req, 400, "invalid_event", "Choose which event you're scanning for.");
  }

  try {
    if (!(await allow(`checkin:${userId}`, 60, 300))) {
      return error(req, 429, "rate_limited", "Scanning too fast. Wait a moment.");
    }
    const ticketId = await verifyTicket(code);
    const result = await rpc<Record<string, unknown>>("check_in_ticket", {
      p_ticket_id: ticketId,
      p_event_id: eventId,
      p_staff_user_id: userId,
    });
    return json(req, result);
  } catch (e) {
    if (e instanceof RpcError && e.message === "not_staff") {
      return error(req, 403, "not_staff", "This account isn't set up for door staff.");
    }
    console.error("check-in failed", e instanceof Error ? e.message : e);
    return error(req, 500, "server_error", "Check-in failed. Scan again.");
  }
});
