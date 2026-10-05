// POST /send-emails   x-cron-secret: <EMAIL_CRON_SECRET>
// Sends due emails from the outbox, including retries. Called every few minutes by pg_cron
// (see the schedule_ticket_emails migration). Not callable without the shared secret.

import { requireEnv } from "../_shared/http.ts";
import { sha256Hex } from "../_shared/crypto.ts";
import { processOutbox } from "../_shared/mailer.ts";

function reply(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return reply(405, { error: "method_not_allowed" });

  let expected: string;
  try {
    expected = requireEnv("EMAIL_CRON_SECRET");
  } catch {
    return reply(503, { error: "not_configured" });
  }
  // Compare hashes so the check takes the same time whatever the input.
  const given = req.headers.get("x-cron-secret") ?? "";
  if ((await sha256Hex(given)) !== (await sha256Hex(expected))) {
    return reply(401, { error: "unauthorised" });
  }

  try {
    return reply(200, await processOutbox(20));
  } catch (e) {
    console.error("send-emails failed", e instanceof Error ? e.message : e);
    return reply(500, { error: "server_error" });
  }
});
