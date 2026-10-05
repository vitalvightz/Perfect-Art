// POST /resend-tickets  { email }
// "Find my tickets". Re-sends the tickets email for every paid order on that address whose event
// hasn't finished. The reply is identical whether or not the address has tickets, so it can't be
// used to find out who has bought tickets.

import { clientIp, error, guard, json, readJson } from "../_shared/http.ts";
import { clientKey } from "../_shared/crypto.ts";
import { allow, allowClient, rpc } from "../_shared/db.ts";
import { processOutbox } from "../_shared/mailer.ts";

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const DONE = "If that address has tickets for an upcoming night, we've emailed them. Check your inbox and spam folder.";

Deno.serve(async (req) => {
  const blocked = guard(req, ["POST"]);
  if (blocked) return blocked;

  const body = await readJson(req);
  const email = typeof body?.email === "string" ? body.email.trim().toLowerCase() : "";
  if (email.length > 254 || !EMAIL_RE.test(email)) {
    return error(req, 400, "invalid_email", "Enter the email address you used to buy your tickets.");
  }

  try {
    const ipOk = await allowClient("resend", await clientKey(clientIp(req)), [600, 5], [600, 200]);
    const emailOk = await allow(`resend:email:${await clientKey(email)}`, 3600, 3);
    if (!ipOk) {
      return error(req, 429, "rate_limited", "Too many requests. Wait a few minutes and try again.");
    }
    if (emailOk && (await rpc<number>("request_ticket_resend", { p_email: email })) > 0) {
      await processOutbox(5).catch((e) => console.error("resend send failed", e instanceof Error ? e.message : e));
    }
    return json(req, { message: DONE }, 202);
  } catch (e) {
    console.error("resend-tickets failed", e instanceof Error ? e.message : e);
    return error(req, 500, "server_error", "Something went wrong. Try again in a few minutes.");
  }
});
