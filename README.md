# Perfect Art

Website and ticketing for Perfect Art, an events business running club nights and bar takeovers in London.

```text
index.html, tickets.html  (static site)
        │  fetch
        ▼
Supabase Edge Functions   events · checkout · order · check-in · payment-webhook
        │  service role, server side only
        ▼
Postgres (Supabase project "Perf Behind the Curtains")
        ▲
        │  signed notifications
Payment provider          (not chosen yet, so ticket sales are closed)
```

## What's in here

| Path | What it is |
|---|---|
| `index.html`, `app.js` | Landing page. Loads the next published event and its ticket types from `/events`. Reserve calls `/checkout`. |
| `tickets.html`, `tickets.js` | The buyer's ticket page. Shows one QR code per ticket once the order is paid. |
| `config.js` | Public settings (the Edge Functions URL). Nothing secret goes here. |
| `vendor/qrcode-generator-1.4.4.js` | QR code library (MIT), served from this site so the CSP can stay at "scripts from this site only". |
| `supabase/migrations/` | Database schema, access rules and all payment/ticket logic. Already applied to the live project. |
| `supabase/functions/` | The five Edge Functions, already deployed. |
| `supabase/tests/` | Database behaviour and race-condition tests. |
| `supabase/seed.sql` | The first event (Opening Night), already added as a draft. |

## Security model

- **The browser can't change anything that matters.** Visitors can only read published events and their ticket types (without capacity or allocation numbers). Every other table has row level security on and no browser access at all.
- **Privileged database functions run as the service role only.** `anon` and `authenticated` can't execute any of them. The service role key only exists inside Edge Functions.
- **Prices come from the database.** The browser sends a ticket type and a quantity, never an amount. Money is stored as integer pence.
- **Only the payment provider can mark an order paid.** That happens in `payment-webhook` after the provider's signature is verified. Reaching the success page proves nothing.
- **Payment notifications are idempotent.** Each provider event id is stored with a unique key, and processing happens in the same transaction, so a notification that arrives twice issues tickets once.
- **The amount paid is checked** against the order before tickets are issued. Mismatches go to `review` with no tickets.
- **No overselling.** Checkout holds seats for 35 minutes while locking the event row, so two buyers can't both take the last seats. The provider's checkout closes at 30 minutes. A payment that arrives after its hold expired is only honoured if seats are still free; otherwise the order goes to `review` for a refund.
- **QR codes are signed** (`PA1.<ticket id>.<HMAC>`) with `TICKET_SIGNING_SECRET`, so they can't be guessed or forged, and can be shown again at any time.
- **Check-in is atomic.** Two scanners on the same ticket at the same moment: one gets "valid", the other "already used". Every scan attempt is logged.
- **Buyer ticket links** carry a 256-bit secret in the URL fragment (never sent to servers). Only its SHA-256 is stored.
- **Rate limits** on events, checkout, order lookups and check-in, stored in the database. Raw IPs are never stored, only a keyed hash.
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

`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are provided automatically.

### 2. Payment provider

Write an adapter in `supabase/functions/_shared/payments/` that implements `PaymentProvider` from `types.ts`:

- `createCheckout()` creates a hosted checkout for exactly `amountPence`, closing by `expiresAt`, and stores `orderId` in the provider's metadata.
- `parseWebhook()` verifies the provider's signature (and throws if it's wrong), then reports `paid` (only once money is captured), `expired` or `refunded`.

Register it in `registry.ts`, redeploy `checkout` and `payment-webhook`, set `PAYMENT_PROVIDER`, and point the provider's webhook at
`https://bsxlhszipbrlisiyuwxh.supabase.co/functions/v1/payment-webhook/<provider name>`.

### 3. Publish the first event

In the Table Editor, open `events` and `ticket_types` and set the real capacity, prices (pence: £15.00 = `1500`), allocations, perks and sales window. Then set the event's `status` to `published`. It appears on the site straight away.

### 4. Door staff

Create the person in **Authentication → Users**, then add a row to `staff` with their user id. Only users in `staff` can check tickets in. (A door scanning page is not built yet; the `check-in` endpoint is ready for it.)

## Tests

```sh
# Database behaviour (69 checks) and race conditions, against a throwaway local Postgres:
PSQL="psql -h localhost -p 5432 -U postgres" supabase/tests/run.sh

# Ticket signing:
deno test --allow-env supabase/functions/_shared/crypto_test.ts

# Type-check the Edge Functions:
deno check supabase/functions/*/index.ts
```

Never point the database tests at the Supabase project: they create their own roles and data.

## Still to do

- Payment provider adapter (see above).
- Door scanning page for staff.
- Emailing tickets to buyers. For now they get their private ticket link on the page they return to after paying.
- The mailing list form shows a confirmation but doesn't store emails yet.
- Brand colours (tokens at the top of each page's `<style>`), Instagram handle and contact email.
