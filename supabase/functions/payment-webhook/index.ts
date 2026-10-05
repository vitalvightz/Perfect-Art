// POST /payment-webhook/<provider>
// Receives payment notifications. The adapter verifies the provider's signature; the database
// functions make processing idempotent and check the amount before issuing any tickets.
// This is the only path by which an order becomes paid.

import { providerByName } from "../_shared/payments/registry.ts";
import { rpc } from "../_shared/db.ts";
import { processOutbox } from "../_shared/mailer.ts";

const NEEDS_ATTENTION = new Set([
  "amount_mismatch",
  "no_capacity_needs_refund",
  "second_payment_needs_refund",
  "order_not_payable_needs_review",
  "order_not_found",
]);

function reply(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return reply(405, { error: "method_not_allowed" });

  const name = new URL(req.url).pathname.split("/").filter(Boolean).pop() ?? "";
  const provider = providerByName(name);
  if (!provider) return reply(404, { error: "unknown_provider" });

  let notice;
  try {
    notice = await provider.parseWebhook(req);
  } catch (e) {
    console.warn("rejected webhook", name, e instanceof Error ? e.message : e);
    return reply(400, { error: "invalid_signature" });
  }

  try {
    let result: { outcome?: string; order_id?: string } = {};
    switch (notice.kind) {
      case "paid":
        result = await rpc("confirm_payment", {
          p_provider: provider.name,
          p_provider_event_id: notice.eventId,
          p_event_type: notice.eventType,
          p_order_id: notice.orderId,
          p_payment_id: notice.paymentId,
          p_amount_pence: notice.amountPence,
          p_currency: notice.currency,
          p_email: notice.email,
        });
        break;
      case "expired":
        result = await rpc("release_order", {
          p_provider: provider.name,
          p_provider_event_id: notice.eventId,
          p_event_type: notice.eventType,
          p_order_id: notice.orderId,
        });
        break;
      case "refunded":
        result = await rpc("refund_order", {
          p_provider: provider.name,
          p_provider_event_id: notice.eventId,
          p_event_type: notice.eventType,
          p_payment_id: notice.paymentId,
          p_full_refund: notice.fullRefund,
        });
        break;
      case "ignored":
        return reply(200, { received: true });
    }

    if (notice.kind === "refunded" && result.outcome === "order_not_found") {
      // Probably arrived before its payment notification. Ask the provider to retry later.
      console.warn("refund for unknown payment, asking provider to retry", { provider: provider.name });
      return reply(503, { error: "retry_later" });
    }
    if (result.outcome === "fulfilled" || result.outcome === "fulfilled_late") {
      // Send the tickets email now. If this fails, the queued email is retried by send-emails.
      await processOutbox(5).catch((e) => console.error("immediate email send failed", e instanceof Error ? e.message : e));
    }
    if (result.outcome && NEEDS_ATTENTION.has(result.outcome)) {
      console.warn("payment needs attention", { provider: provider.name, outcome: result.outcome, order: result.order_id });
    }
    return reply(200, { received: true });
  } catch (e) {
    // A 5xx makes the provider retry later, which is safe because processing is idempotent.
    console.error("webhook processing failed", e instanceof Error ? e.message : e);
    return reply(500, { error: "server_error" });
  }
});
