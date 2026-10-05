// POST /checkout  { ticket_type_id, quantity }
// Holds the seats, creates a pending order priced from the database, and returns the payment
// provider's hosted checkout URL. The client never sends a price.

import { clientIp, error, guard, json, readJson, requireEnv, UUID_RE } from "../_shared/http.ts";
import { clientKey, orderLinkToken, sha256Hex } from "../_shared/crypto.ts";
import { allow, rpc, RpcError } from "../_shared/db.ts";
import { activeProvider } from "../_shared/payments/registry.ts";

const HOLD_MINUTES = 35;
// The provider's checkout closes well before our hold ends, so a payment can't land after the
// seats were released.
const CHECKOUT_MINUTES = 30;

type Reservation = {
  order_id: string;
  quantity: number;
  unit_price_pence: number;
  amount_pence: number;
  currency: string;
  ticket_name: string;
  event_name: string;
};

const RESERVE_ERRORS: Record<string, [number, string]> = {
  not_on_sale: [409, "These tickets aren't on sale right now."],
  sold_out: [409, "Sorry, there aren't enough of these tickets left."],
  invalid_quantity: [400, "Choose a quantity within the limit for this ticket."],
};

Deno.serve(async (req) => {
  const blocked = guard(req, ["POST"]);
  if (blocked) return blocked;

  const body = await readJson(req);
  const ticketTypeId = body?.ticket_type_id;
  const quantity = body?.quantity;
  if (typeof ticketTypeId !== "string" || !UUID_RE.test(ticketTypeId)) {
    return error(req, 400, "invalid_ticket_type", "Pick a ticket type.");
  }
  if (typeof quantity !== "number" || !Number.isInteger(quantity) || quantity < 1 || quantity > 20) {
    return error(req, 400, "invalid_quantity", "Choose a quantity between 1 and 20.");
  }

  try {
    const ipKey = await clientKey(clientIp(req));
    if (!(await allow(`checkout:${ipKey}`, 600, 10))) {
      return error(req, 429, "rate_limited", "Too many checkout attempts. Wait a few minutes and try again.");
    }

    const provider = activeProvider();
    if (!provider) {
      return error(req, 503, "sales_closed", "Ticket sales open soon.");
    }
    const siteUrl = requireEnv("SITE_URL").replace(/\/+$/, "");

    // The buyer's private ticket link secret, derived from the order id. Only its hash is stored,
    // and it is never sent to the payment provider: the browser gets it in this response, and the
    // ticket email carries it.
    const orderId = crypto.randomUUID();
    const accessToken = await orderLinkToken(orderId);

    let order: Reservation;
    try {
      order = await rpc<Reservation>("reserve_tickets", {
        p_order_id: orderId,
        p_ticket_type_id: ticketTypeId,
        p_quantity: quantity,
        p_access_token_hash: await sha256Hex(accessToken),
        p_client_key: ipKey,
        p_hold_minutes: HOLD_MINUTES,
      });
    } catch (e) {
      if (e instanceof RpcError && Object.hasOwn(RESERVE_ERRORS, e.message)) {
        const [status, message] = RESERVE_ERRORS[e.message];
        return error(req, status, e.message, message);
      }
      throw e;
    }

    let session;
    try {
      session = await provider.createCheckout({
        orderId: order.order_id,
        amountPence: order.amount_pence,
        currency: order.currency,
        quantity: order.quantity,
        unitPricePence: order.unit_price_pence,
        description: `${order.event_name}: ${order.ticket_name}`,
        // Only the order id, which unlocks nothing on its own. The provider never sees the secret.
        successUrl: `${siteUrl}/tickets.html?order=${order.order_id}`,
        cancelUrl: `${siteUrl}/#tickets`,
        expiresAt: new Date(Date.now() + CHECKOUT_MINUTES * 60_000),
      });
    } catch (e) {
      await rpc("cancel_pending_order", { p_order_id: order.order_id }).catch(() => {});
      console.error("provider checkout failed", provider.name, e instanceof Error ? e.message : e);
      return error(req, 502, "payment_unavailable", "Payment is temporarily unavailable. Try again shortly.");
    }

    await rpc("attach_checkout", {
      p_order_id: order.order_id,
      p_provider: provider.name,
      p_checkout_id: session.checkoutId,
    });

    // The page keeps ticket_ref in this browser so it can show the tickets straight after payment.
    return json(req, { redirect_url: session.redirectUrl, ticket_ref: `${order.order_id}.${accessToken}` });
  } catch (e) {
    console.error("checkout failed", e instanceof Error ? e.message : e);
    return error(req, 500, "server_error", "Something went wrong. Your card has not been charged. Try again.");
  }
});
