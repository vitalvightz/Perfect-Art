# Perfect Art

Website and ticketing for Perfect Art, an events business running club nights and bar takeovers in London.

```text
index.html, tickets.html  (static site)
        │  fetch
        ▼
Supabase Edge Functions   events · checkout · order · check-in · payment-webhook · resend-tickets · send-emails
        │  service role, server side only
        ▼
Postgres (Supabase project "Perf Behind the Curtains")
        ▲                       │ pg_cron every 2 min → send-emails (retries)
        │  signed notifications ▼
Payment provider          Email provider
(not chosen yet:          (not chosen yet: emails wait in
 sales are closed)         the queue until one is set up)
```

## What's in here

| Path | What it is |
|---|---|
| `index.html`, `app.js` | Landing page. Loads the next published event and its ticket types from `/events`. Reserve calls `/checkout`. |
| `tickets.html`, `tickets.js` | The buyer's ticket page. Shows one QR code per ticket once the order is paid. Without a link it's the "Find my tickets" page, which re-sends the tickets email. |
| `config.js` | Public settings (the Edge Functions URL). Nothing secret goes here. |
| `vendor/qrcode-generator-1.4.4.js` | QR code library (MIT), served from this site so the CSP can stay at "scripts from this site only". |
| `supabase/migrations/` | Database schema, access rules and all payment/ticket logic. Already applied to the live project. |
| `supabase/functions/` | The seven Edge Functions, already deployed. |
| `supabase/tests/` | Database behaviour and race-condition tests. |
| `tests/site_test.cjs` | Browser tests for both pages, with the API mocked. |
| `.github/workflows/tests.yml` | Runs every test on GitHub for each push and pull request. |
| `supabase/seed.sql` | The first event (Opening Night), already added as a draft. |

## Security model

- **The browser can't change anything that matters.** Visitors can only read published events and their ticket types (without capacity or allocation numbers). Signed-in staff can read their own `staff` row. Every other table has row level security on and no browser access at all, and nothing is writable from the browser.
- **Privileged database functions run as the service role only.** `anon` and `authenticated` can't execute any of them. The service role key only exists inside Edge Functions.
- **Prices come from the database.** The browser sends a ticket type and a quantity, never an amount. Money is stored as integer pence.
- **Only the payment provider can mark an order paid.** That happens in `payment-webhook` after the provider's signature is verified. Reaching the success page proves nothing.
- **Payment notifications are idempotent.** Each provider event id is stored with a unique key, and processing happens in the same transaction, so a notification that arrives twice issues tickets once.
- **The amount paid is checked** against the order before tickets are issued. Mismatches go to `review` with no tickets.
- **No overselling.** Checkout holds seats for 35 minutes while locking the event row, so two buyers can't both take the last seats. The provider's checkout closes at 30 minutes. Payment confirmation takes the same lock and checks the hold against the wall clock, so a payment landing just as its hold expires can't race a new buyer for the same seat. A payment that arrives after its hold expired is only honoured if seats are still free; otherwise the order goes to `review` for a refund.
- **Out-of-order notifications.** A refund that arrives before its payment notification isn't marked processed; the webhook asks the provider to retry, and it's applied once the payment has landed.
- **QR codes are signed** (`PA1.<ticket id>.<HMAC>`) with `TICKET_SIGNING_SECRET`, so they can't be guessed or forged, and can be shown again at any time.
- **Check-in is atomic.** Two scanners on the same ticket at the same moment: one gets "valid", the other "already used". Every scan attempt is logged.
- **Buyer ticket links** (`tickets.html#<order id>.<secret>`) carry a 256-bit secret derived from the order id with `TICKET_SIGNING_SECRET`. Only its SHA-256 is stored. The secret is **never sent to the payment provider**: the provider's success URL is `tickets.html?order=<order id>`, which unlocks nothing. The secret reaches the buyer two ways: in the checkout response (kept in their browser so the tickets show straight after paying) and in the tickets email. As a URL fragment, browsers don't send it to any server when the page loads.
- **Tickets are emailed** through an outbox. `confirm_payment` queues the email in the same transaction that issues the tickets, so a paid order can't end up without one. It's sent straight away, and anything that fails is retried by `send-emails` (every 2 minutes from `pg_cron`, after 2, 4, 8, 16 and 32 minutes, then marked failed). Parallel senders can't send the same email twice.
- **"Find my tickets"** re-sends tickets to the address used at checkout. It gives the same reply whether or not the address has tickets, and is rate limited per IP and per address.
- **Rate limits** on every public endpoint, stored in the database: per client (by IP, preferring Cloudflare's `cf-connecting-ip`) and a global ceiling per endpoint that still holds if someone fakes a new IP on every request. Raw IPs are never stored, only a keyed hash. Request bodies are capped at 4 KB while being read.
- **CORS** only allows the origins in `ALLOWED_ORIGINS`. Pages ship a strict Content-Security-Policy.

## Setup still needed

### 1. Edge Function secrets

In Supabase: **Edge Functions → Secrets**, add:

| Secret | Value |
|---|---|
| `TICKET_SIGNING_SECRET` | A long random string (at least 32 characters). Generate one with `openssl rand -base64 48`. Keep it forever: changing it invalidates every issued QR code. |
| `ALLOWED_ORIGINS` | The site's address(es), comma separated, e.g. `https://perfectart.co.uk,https://www.perfectart.co.uk` |
| `SITE_URL` | The site's main address, e.g. `https://perfectart.co.uk`. Used for the after-payment and cancel links. |
| `PAYMENT_PROVIDER` | Leave unset until a provider adapter exists. While unset, checkout replies "Ticket sales open soon". |
| `EMAIL_PROVIDER` | Leave unset until an email adapter exists. While unset, emails wait in the queue and go out once it's set. |
| `EMAIL_CRON_SECRET` | Lets the scheduled job call `send-emails`. The value was generated in the database: copy it from **SQL editor** → `select decrypted_secret from vault.decrypted_secrets where name = 'email_cron_secret';` |

`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are provided automatically.

### 2. Payment provider

Write an adapter in `supabase/functions/_shared/payments/` that implements `PaymentProvider` from `types.ts`:

- `createCheckout()` creates a hosted checkout for exactly `amountPence`, closing by `expiresAt`, and stores `orderId` in the provider's metadata.
- `parseWebhook()` verifies the provider's signature (and throws if it's wrong), then reports `paid` (only once money is captured), `expired` or `refunded`.

Register it in `registry.ts`, redeploy `checkout` and `payment-webhook`, set `PAYMENT_PROVIDER`, and point the provider's webhook at
`https://bsxlhszipbrlisiyuwxh.supabase.co/functions/v1/payment-webhook/<provider name>`.

### 3. Email provider

Write an adapter in `supabase/functions/_shared/email/` that implements `EmailSender` from `types.ts` (one `send()` method; pass `idempotencyKey` to the provider if it supports one, and throw `PermanentEmailError` for errors a retry won't fix). Register it in `registry.ts`, redeploy `payment-webhook`, `send-emails` and `resend-tickets`, and set `EMAIL_PROVIDER`. Set up the sending domain's SPF/DKIM records with the provider so tickets don't land in spam.

### 4. Publish the first event

In the Table Editor, open `events` and `ticket_types` and set the real capacity, prices (pence: £15.00 = `1500`), allocations and perks. **Set `sales_start` and `sales_end`** on each ticket type: if they're left empty, tickets go on sale the moment the event is published. Then set the event's `status` to `published`. It appears on the site within a minute.

The site shows the first **two** ticket types of the next event (lowest `sort_order` first), matching its two ticket cards. A third type would need a third card in `index.html`.

### 5. Door staff

Create the person in **Authentication → Users**, then add a row to `staff` with their user id. Only users in `staff` can check tickets in. (A door scanning page is not built yet; the `check-in` endpoint is ready for it.)

### 6. Two small clean-ups (optional)

The tool used to apply migrations here can't run destructive statements, so these are left for you. Run them in the **SQL editor**:

```sql
-- Old reserve_tickets signature. Nothing can call it (no role has execute), so this is tidying only.
drop function public.reserve_tickets(uuid, integer, text, text, integer);

-- Move pg_net out of the public schema (clears the security advisor warning). Run together:
drop extension pg_net;
create extension pg_net with schema extensions;
```

## Tests

```sh
# Database behaviour (86 checks) and race conditions, against a throwaway local Postgres:
PSQL="psql -h localhost -p 5432 -U postgres" supabase/tests/run.sh

# Ticket signing and email content:
deno test --allow-env supabase/functions/_shared/

# Site, in a real browser with the API mocked:
npm install --no-save playwright@1.56.1 && npx playwright install chromium && node tests/site_test.cjs

# Type-check the Edge Functions:
deno check supabase/functions/*/index.ts
```

Never point the database tests at the Supabase project: they create their own roles and data. GitHub Actions runs all of these on every push and pull request.

## Still to do

- Payment provider adapter (see above).
- Email provider adapter (see above).
- Door scanning page for staff.
- The mailing list form shows a confirmation but doesn't store emails yet.
- Brand colours (tokens at the top of each page's `<style>`), Instagram handle and contact email.
