// Sends queued emails from the email_outbox table.
// Safe to run from several places at once: the database hands each email to one sender only.

import { requireEnv } from "./http.ts";
import { orderLinkToken } from "./crypto.ts";
import { rpc } from "./db.ts";
import { activeEmailSender } from "./email/registry.ts";
import { PermanentEmailError } from "./email/types.ts";

type Claim = { id: string; order_id: string; kind: "tickets" | "resend"; to_email: string; attempts: number };

export type OrderDetails = {
  order_id: string;
  status: string;
  quantity: number;
  ticket_name: string;
  event: { name: string; venue: string; address: string; doors_at: string; ends_at: string; min_age: number };
};

const TZ = "Europe/London";
const dateFmt = new Intl.DateTimeFormat("en-GB", { timeZone: TZ, weekday: "long", day: "numeric", month: "long", year: "numeric" });
const timeFmt = new Intl.DateTimeFormat("en-GB", { timeZone: TZ, hour: "2-digit", minute: "2-digit" });
const date = (iso: string) => dateFmt.formatToParts(new Date(iso)).filter((p) => p.type !== "literal").map((p) => p.value).join(" ");

function esc(s: string): string {
  return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
}

export function ticketEmail(d: OrderDetails, link: string, kind: Claim["kind"]) {
  const ev = d.event;
  const when = `${date(ev.doors_at)}, doors ${timeFmt.format(new Date(ev.doors_at))}`;
  const what = `${d.quantity} × ${d.ticket_name}`;
  const subject = kind === "resend" ? `Your tickets for ${ev.name} (sent again)` : `Your tickets for ${ev.name}`;
  const lines = [
    kind === "resend" ? "Here are your Perfect Art tickets again." : "You're in. Here are your Perfect Art tickets.",
    "",
    `${ev.name}`,
    `${when}`,
    `${ev.address}`,
    `${what}`,
    "",
    `Open your tickets: ${link}`,
    "",
    `Show the QR code at the door with photo ID. This is an ${ev.min_age}+ event. Each code works once.`,
    "Don't forward this email or share the link: anyone with it can use your tickets.",
    "",
    "Perfect Art",
  ];
  const html = `<!doctype html><html><body style="margin:0;padding:24px;background:#f4f4f3;font-family:Arial,Helvetica,sans-serif;color:#111112">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:520px;margin:0 auto;background:#ffffff;border:1px solid #d9d9db">
<tr><td style="padding:28px 28px 8px;font-weight:bold;letter-spacing:2px;font-size:14px">PERFECT ART</td></tr>
<tr><td style="padding:8px 28px 0;font-size:15px;color:#5d5d61">${esc(lines[0])}</td></tr>
<tr><td style="padding:16px 28px 0"><div style="font-size:26px;font-weight:bold;line-height:1.15">${esc(ev.name)}</div>
<div style="margin-top:8px;font-size:15px;line-height:1.5">${esc(when)}<br>${esc(ev.address)}<br><strong>${esc(what)}</strong></div></td></tr>
<tr><td style="padding:24px 28px"><a href="${esc(link)}" style="display:inline-block;background:#111112;color:#ffffff;text-decoration:none;padding:14px 24px;border-radius:999px;font-weight:bold">Open your tickets</a></td></tr>
<tr><td style="padding:0 28px 28px;font-size:13px;line-height:1.5;color:#5d5d61">Show the QR code at the door with photo ID. This is an ${ev.min_age}+ event. Each code works once.<br><br>Don't forward this email or share the link: anyone with it can use your tickets.<br><br>If the button doesn't work, copy this link into your browser:<br><span style="word-break:break-all">${esc(link)}</span></td></tr>
</table></body></html>`;
  return { subject, html, text: lines.join("\n") };
}

/** Sends up to `limit` due emails. Does nothing while no email provider is configured. */
export async function processOutbox(limit = 10): Promise<{ sent: number; failed: number; waiting: boolean }> {
  const sender = activeEmailSender();
  if (!sender) return { sent: 0, failed: 0, waiting: true };
  const siteUrl = requireEnv("SITE_URL").replace(/\/+$/, "");

  const claims = await rpc<Claim[]>("claim_emails", { p_limit: limit });
  let sent = 0, failed = 0;
  for (const c of claims) {
    try {
      const d = await rpc<OrderDetails | null>("order_email_details", { p_order_id: c.order_id });
      if (!d || d.status !== "paid") {
        await rpc("mark_email_failed", { p_email_id: c.id, p_error: "order_not_paid", p_permanent: true });
        failed++;
        continue;
      }
      const link = `${siteUrl}/tickets.html#${c.order_id}.${await orderLinkToken(c.order_id)}`;
      const { messageId } = await sender.send({ to: c.to_email, ...ticketEmail(d, link, c.kind), idempotencyKey: `pa-email-${c.id}` });
      await rpc("mark_email_sent", { p_email_id: c.id, p_provider_message_id: messageId });
      sent++;
    } catch (e) {
      failed++;
      const message = e instanceof Error ? e.message : String(e);
      // Never log the address or the link.
      console.error("email send failed", { email: c.id, attempt: c.attempts, error: message });
      await rpc("mark_email_failed", {
        p_email_id: c.id,
        p_error: message,
        p_permanent: e instanceof PermanentEmailError,
      }).catch(() => {});
    }
  }
  return { sent, failed, waiting: false };
}
