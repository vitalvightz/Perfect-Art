// deno test --allow-env supabase/functions/_shared/mailer_test.ts
Deno.env.set("TICKET_SIGNING_SECRET", "test-secret-that-is-at-least-32-characters-long");
Deno.env.set("SUPABASE_URL", "http://localhost:54321");
Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "test-key");
const { ticketEmail } = await import("./mailer.ts");
const { orderLinkToken } = await import("./crypto.ts");

function assert(cond: unknown, msg: string): asserts cond {
  if (!cond) throw new Error(msg);
}

const details = {
  order_id: "3f2b8c1e-6d4a-4f7b-9a0c-1e2d3f4a5b6c",
  status: "paid",
  quantity: 2,
  ticket_name: "VIP Entry",
  event: {
    name: `Opening <script>alert("x")</script> Night`,
    venue: "Shoreditch 45",
    address: "Shoreditch 45, London",
    doors_at: "2026-10-17T21:00:00Z",
    ends_at: "2026-10-18T03:00:00Z",
    min_age: 18,
  },
};
const link = "https://perfectart.example/tickets.html#3f2b8c1e-6d4a-4f7b-9a0c-1e2d3f4a5b6c.abc";

Deno.test("tickets email has the link, event details and London time", () => {
  const m = ticketEmail(details, link, "tickets");
  assert(m.subject.startsWith("Your tickets for Opening"), m.subject);
  assert(m.html.includes(`href="${link}"`) && m.text.includes(link), "link missing");
  assert(m.text.includes("Saturday 17 October 2026, doors 22:00"), "London time missing: " + m.text);
  assert(m.text.includes("2 × VIP Entry") && m.text.includes("18+"), "order details missing");
});

Deno.test("event text is escaped in the HTML email", () => {
  const m = ticketEmail(details, link, "tickets");
  assert(!m.html.includes("<script>"), "unescaped script tag");
  assert(m.html.includes("&lt;script&gt;"), "escaped text missing");
});

Deno.test("re-send email says it was sent again", () => {
  assert(ticketEmail(details, link, "resend").subject.includes("(sent again)"), "resend subject");
});

Deno.test("order link token is stable per order and different between orders", async () => {
  const a1 = await orderLinkToken(details.order_id), a2 = await orderLinkToken(details.order_id);
  const b = await orderLinkToken("00000000-0000-0000-0000-000000000001");
  assert(a1 === a2 && a1 !== b && /^[A-Za-z0-9_-]{43}$/.test(a1), "bad token");
});
