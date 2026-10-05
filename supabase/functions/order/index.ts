// POST /order  { ref: "<order id>.<link secret>" }
// The buyer's ticket page. Returns the order and, once paid, a signed QR code per ticket.
// Requires the secret from the buyer's private link.

import { clientIp, error, guard, json, readJson, UUID_RE } from "../_shared/http.ts";
import { clientKey, sha256Hex, signTicket } from "../_shared/crypto.ts";
import { allow, rpc } from "../_shared/db.ts";

type Order = {
  id: string;
  status: string;
  email: string | null;
  tickets: { id: string; status: string; checked_in_at: string | null }[];
  [key: string]: unknown;
};

function maskEmail(email: string | null): string | null {
  if (!email) return null;
  const [user, domain] = email.split("@");
  return domain ? `${user.slice(0, 1)}***@${domain}` : null;
}

Deno.serve(async (req) => {
  const blocked = guard(req, ["POST"]);
  if (blocked) return blocked;

  const body = await readJson(req);
  const ref = typeof body?.ref === "string" ? body.ref : "";
  const [orderId, token] = ref.split(".");
  if (!orderId || !UUID_RE.test(orderId) || !token || !/^[A-Za-z0-9_-]{43}$/.test(token)) {
    return error(req, 400, "invalid_link", "This ticket link isn't complete. Open it again from your confirmation.");
  }

  try {
    if (!(await allow(`order:${await clientKey(clientIp(req))}`, 60, 30))) {
      return error(req, 429, "rate_limited", "Too many requests. Wait a minute and try again.");
    }

    const order = await rpc<Order | null>("get_order", {
      p_order_id: orderId,
      p_access_token_hash: await sha256Hex(token),
    });
    if (!order) {
      return error(req, 404, "not_found", "We couldn't find this order. Check you opened the full link.");
    }

    const tickets = await Promise.all(order.tickets.map(async (t) => ({
      ...t,
      code: t.status === "active" ? await signTicket(t.id) : null,
    })));

    return json(req, { ...order, email: maskEmail(order.email), tickets });
  } catch (e) {
    console.error("order lookup failed", e instanceof Error ? e.message : e);
    return error(req, 500, "server_error", "Couldn't load your tickets. Try again shortly.");
  }
});
