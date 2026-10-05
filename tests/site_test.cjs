// Browser tests for index.html and tickets.html, with the ticket API mocked.
// Run: npm i --no-save playwright@1.56.1 && npx playwright install chromium && node tests/site_test.cjs
const { chromium } = require('playwright');
const API = 'https://bsxlhszipbrlisiyuwxh.supabase.co/functions/v1';
const path = require('path');
const ROOT = 'file://' + path.resolve(__dirname, '..');
const SHOTS = process.env.SCREENSHOTS; // optional folder for screenshots
const fail = m => { console.log('FAIL - ' + m); process.exitCode = 1; };
const ok = (c, m) => c ? console.log('ok - ' + m) : fail(m);

(async () => {
  const b = await chromium.launch();
  const p = await b.newPage({ viewport: { width: 1280, height: 900 } });
  const errors = []; p.on('pageerror', e => errors.push(e.message));
  p.on('console', m => { if (m.type() === 'error' && !/fonts|ERR_|status of 503/.test(m.text())) errors.push(m.text()); });
  let checkoutBody = null, checkoutStatus = 503;
  await p.route(API + '/events', r => r.fulfill({ contentType: 'application/json', body: JSON.stringify({ events: [{
    id: 'e1', name: 'Halloween Special', kind: 'club', venue: 'Shoreditch 45', address: 'Shoreditch 45, London',
    doors_at: '2026-10-31T22:00:00Z', ends_at: '2026-11-01T04:00:00Z', min_age: 18,
    ticket_types: [
      { id: '20000000-0000-0000-0000-000000000001', name: 'Early Bird', perks: ['Entry before 23:00', 'Main room'], price_pence: 1250, currency: 'gbp', max_per_order: 4, sale_state: 'on_sale' },
      { id: '20000000-0000-0000-0000-000000000002', name: 'VIP Entry', perks: [], price_pence: 3000, currency: 'gbp', max_per_order: 6, sale_state: 'sold_out' } ] }] }) }));
  await p.route(API + '/checkout', r => { checkoutBody = JSON.parse(r.request().postData());
    r.fulfill({ status: checkoutStatus, contentType: 'application/json', body: JSON.stringify(checkoutStatus === 503 ? { error: 'sales_closed', message: 'Ticket sales open soon.' } : { redirect_url: 'https://pay.example/checkout/abc', ticket_ref: '11111111-1111-1111-1111-111111111111.' + 'A'.repeat(43) }) }); });
  await p.route('https://pay.example/**', r => r.fulfill({ body: 'provider page' }));

  await p.goto(ROOT + '/index.html'); await p.waitForTimeout(800);
  const t1 = p.locator('.ticket').nth(0), t2 = p.locator('.ticket').nth(1);
  ok(await p.textContent('#nextName') === 'Halloween Special', 'hero shows the live event name');
  ok((await p.textContent('#nextMeta')).includes('Sat 31 Oct · Doors 22:00 · Shoreditch 45, London'), 'hero shows London-time doors and address: ' + await p.textContent('#nextMeta'));
  ok(await t1.locator('h3').textContent() === 'Early Bird', 'ticket 1 name from the database');
  ok(await t1.locator('.price').textContent() === '£12.50', 'ticket 1 price from the database');
  ok((await t1.locator('li').allTextContents()).join('|') === 'Entry before 23:00|Main room', 'ticket 1 perks from the database');
  ok(await t1.locator('.placeholder-badge').isHidden(), 'placeholder badge hidden once live');
  ok(await t2.locator('.price').textContent() === '£30.00', 'ticket 2 price');
  ok(await t2.locator('.reserve').isDisabled() && await t2.locator('.reserve').textContent() === 'Sold out', 'sold-out ticket disabled');
  ok(await t2.locator('li').count() === 0 && await t2.locator('ul').isHidden(), 'no perks in the database: placeholder perks removed');
  for (let i = 0; i < 6; i++) await t1.locator('[data-step="1"]').click({ force: true });
  ok(await t1.locator('output').textContent() === '4', 'quantity capped at the max per order (4)');

  await t1.locator('.reserve').click(); await p.waitForTimeout(400);
  ok(JSON.stringify(checkoutBody) === JSON.stringify({ ticket_type_id: '20000000-0000-0000-0000-000000000001', quantity: 4 }), 'checkout sends only ticket type and quantity: ' + JSON.stringify(checkoutBody));
  ok((await p.textContent('#toast')) === 'Ticket sales open soon.', 'sales-closed message shown');
  ok(!(await t1.locator('.reserve').isDisabled()), 'Reserve re-enabled after a refusal');

  checkoutStatus = 200;
  await Promise.all([p.waitForURL('https://pay.example/**'), t1.locator('.reserve').click()]);
  ok(p.url() === 'https://pay.example/checkout/abc', 'buyer is sent to the provider checkout');
  if (SHOTS) await p.screenshot({ path: SHOTS + '/home.png' });
  const stored = await (async () => { await p.goto(ROOT + '/index.html'); return p.evaluate(() => localStorage.getItem('pa-ticket:11111111-1111-1111-1111-111111111111')); })();
  ok(stored === '11111111-1111-1111-1111-111111111111.' + 'A'.repeat(43), 'ticket link kept in this browser before going to payment');
  ok(!(await p.getAttribute('footer a[href="tickets.html"]', 'href') === null), 'footer has a Find my tickets link');

  // Ticket page
  const ref = '11111111-1111-1111-1111-111111111111.' + 'A'.repeat(43);
  let status = 'pending', orderBody = null, calls = 0;
  await p.route(API + '/order', r => { calls++; orderBody = JSON.parse(r.request().postData());
    r.fulfill({ contentType: 'application/json', body: JSON.stringify({
      id: 'o', status, quantity: 2, amount_pence: 2500, currency: 'gbp', email: 'b***@example.com', ticket_name: 'Early Bird',
      event: { name: 'Halloween Special', venue: 'Shoreditch 45', address: 'Shoreditch 45, London', doors_at: '2026-10-31T22:00:00Z', ends_at: '2026-11-01T04:00:00Z', min_age: 18 },
      tickets: status === 'paid' ? [
        { id: 'a', status: 'active', checked_in_at: null, code: 'PA1.3f2b8c1e-6d4a-4f7b-9a0c-1e2d3f4a5b6c.' + 'x'.repeat(43) },
        { id: 'b', status: 'used', checked_in_at: '2026-10-31T22:41:00Z', code: null } ] : [] }) }); });
  const p2 = await b.newPage({ viewport: { width: 390, height: 844 }, colorScheme: 'dark' });
  p2.on('pageerror', e => errors.push(e.message));
  await p2.route(API + '/order', r => { calls++; orderBody = JSON.parse(r.request().postData());
    r.fulfill({ contentType: 'application/json', body: JSON.stringify({
      id: 'o', status, quantity: 2, amount_pence: 2500, currency: 'gbp', email: 'b***@example.com', ticket_name: 'Early Bird',
      event: { name: 'Halloween Special', venue: 'Shoreditch 45', address: 'Shoreditch 45, London', doors_at: '2026-10-31T22:00:00Z', ends_at: '2026-11-01T04:00:00Z', min_age: 18 },
      tickets: status === 'paid' ? [
        { id: 'a', status: 'active', checked_in_at: null, code: 'PA1.3f2b8c1e-6d4a-4f7b-9a0c-1e2d3f4a5b6c.' + 'x'.repeat(43) },
        { id: 'b', status: 'used', checked_in_at: '2026-10-31T22:41:00Z', code: null } ] : [] }) }); });
  await p2.goto(ROOT + '/tickets.html#' + ref); await p2.waitForTimeout(600);
  ok(orderBody && orderBody.ref === ref, 'ticket page sends the link reference');
  ok((await p2.textContent('#status')).includes('Confirming your payment'), 'pending order shows confirming state');
  status = 'paid'; await p2.waitForTimeout(3500);
  ok(calls >= 2, 'page re-checks while payment is confirming');
  ok(await p2.locator('.qr img').count() === 1, 'one QR code for the active ticket');
  ok((await p2.getAttribute('.qr img', 'src')).startsWith('data:image/gif'), 'QR rendered locally as an image');
  ok((await p2.textContent('.used')).includes('Checked in at 22:41'), 'used ticket shows check-in time in London time (GMT after 25 Oct)');
  ok(await p2.isHidden('#status') && await p2.isVisible('#tip'), 'status hidden, keep-this-page tip shown');
  const sw = await p2.evaluate(() => document.documentElement.scrollWidth);
  ok(sw <= 390, 'no sideways scroll on a phone (' + sw + 'px)');
  if (SHOTS) await p2.screenshot({ path: SHOTS + '/tickets.png', fullPage: true });

  // Back from payment in the same browser: only ?order= in the URL, secret comes from storage.
  status = 'paid';
  let seenRef = null;
  await p.route(API + '/order', r => { seenRef = JSON.parse(r.request().postData()).ref;
    r.fulfill({ contentType: 'application/json', body: JSON.stringify({ id: 'o', status: 'paid', quantity: 1, amount_pence: 1250, currency: 'gbp', email: 'b***@example.com', ticket_name: 'Early Bird',
      event: { name: 'Halloween Special', venue: 'v', address: 'Shoreditch 45, London', doors_at: '2026-10-31T22:00:00Z', ends_at: '2026-11-01T04:00:00Z', min_age: 18 },
      tickets: [{ id: 'a', status: 'active', checked_in_at: null, code: 'PA1.3f2b8c1e-6d4a-4f7b-9a0c-1e2d3f4a5b6c.' + 'x'.repeat(43) }] }) }); });
  await p.goto(ROOT + '/tickets.html?order=11111111-1111-1111-1111-111111111111'); await p.waitForTimeout(700);
  ok(seenRef === ref, 'return from payment uses the link saved in this browser');
  ok(p.url().endsWith('#' + ref) && !p.url().includes('?order='), 'address bar switched to the bookmarkable link');
  ok(await p.locator('.qr img').count() === 1, 'tickets shown straight after payment');
  ok((await p.textContent('#tip')).includes("We've also emailed these tickets to b***@example.com"), 'page says the tickets were emailed');

  // Back from payment on another device: no saved link.
  const p4 = await b.newPage();
  let resendBody = null;
  await p4.route(API + '/resend-tickets', r => { resendBody = JSON.parse(r.request().postData());
    r.fulfill({ status: 202, contentType: 'application/json', body: JSON.stringify({ message: "If that address has tickets for an upcoming night, we've emailed them. Check your inbox and spam folder." }) }); });
  await p4.goto(ROOT + '/tickets.html?order=22222222-2222-2222-2222-222222222222'); await p4.waitForTimeout(400);
  ok((await p4.textContent('#status')).includes('being emailed'), 'other device: told tickets are being emailed');
  ok(await p4.isVisible('#find'), 'other device: Find my tickets form shown');
  await p4.fill('#findEmail', 'not-an-email'); await p4.click('#findBtn');
  ok((await p4.textContent('#findMsg')).includes('valid email'), 'bad email rejected in the page');
  await p4.fill('#findEmail', ' buyer@example.com '); await p4.click('#findBtn'); await p4.waitForTimeout(300);
  ok(resendBody && resendBody.email === 'buyer@example.com', 'resend sends just the trimmed email');
  ok((await p4.textContent('#findMsg')).includes("we've emailed them"), 'resend confirmation shown');
  if (SHOTS) await p4.screenshot({ path: SHOTS + '/find.png', fullPage: true });

  const p5 = await b.newPage(); await p5.goto(ROOT + '/tickets.html'); await p5.waitForTimeout(200);
  ok(await p5.isHidden('#status') && await p5.isVisible('#find'), 'plain tickets.html is the Find my tickets page');

  const p6 = await b.newPage(); p6.on('pageerror', e => errors.push(e.message));
  await p6.goto(ROOT + '/tickets.html#%E0%A4%A'); await p6.waitForTimeout(200);
  ok((await p6.textContent('#status')).includes("isn't complete"), 'malformed link escape handled without a crash');

  const p3 = await b.newPage(); await p3.goto(ROOT + '/tickets.html#not-a-real-link');
  ok((await p3.textContent('#status')).includes("isn't complete") && await p3.isVisible('#find'), 'broken link handled, with recovery form');

  ok(errors.length === 0, 'no script errors' + (errors.length ? ': ' + errors.join(' | ') : ''));
  await b.close();
  if (!process.exitCode) console.log('SITE TESTS PASSED');
})().catch(e => { console.error(e); process.exit(1); });
