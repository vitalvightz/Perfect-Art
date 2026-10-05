-- Behaviour tests for the ticketing core. Run against a throwaway database:
--   see run.sh
\set ON_ERROR_STOP 1
\set QUIET 1

create function pg_temp.ok(cond boolean, msg text) returns void language plpgsql as $$
begin
  if cond is not true then raise exception 'FAIL: %', msg; end if;
  raise notice 'ok - %', msg;
end $$;

-- Runs sql as the current role and returns the error message, or null if it succeeded.
create function pg_temp.err(sql text) returns text language plpgsql as $$
begin
  execute sql;
  return null;
exception when others then
  return sqlerrm;
end $$;
grant execute on function pg_temp.ok(boolean, text), pg_temp.err(text) to anon, authenticated, service_role;

-- ---------------------------------------------------------------- fixtures (as owner)
insert into auth.users (id) values
  ('00000000-0000-0000-0000-00000000000a'),  -- staff
  ('00000000-0000-0000-0000-00000000000b');  -- ordinary user
insert into public.staff (user_id, role) values ('00000000-0000-0000-0000-00000000000a', 'staff');

insert into public.events (id, name, kind, venue, address, doors_at, ends_at, capacity, status) values
  ('10000000-0000-0000-0000-000000000001', 'Opening Night', 'club', 'Shoreditch 45', 'Shoreditch 45, London',
   now() + interval '10 days', now() + interval '10 days 6 hours', 5, 'published'),
  ('10000000-0000-0000-0000-000000000002', 'Secret Draft', 'bar', 'TBC', 'TBC',
   now() + interval '20 days', now() + interval '20 days 6 hours', 100, 'draft');

insert into public.ticket_types (id, event_id, name, price_pence, allocation, max_per_order, sort_order) values
  ('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'General Entry', 1500, 4, 4, 1),
  ('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'VIP Entry', 3000, 3, 4, 2),
  ('20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000002', 'Draft Ticket', 1000, 50, 4, 1);

-- ---------------------------------------------------------------- browser roles
set role anon;
select pg_temp.ok((select count(*) from public.events) = 1, 'anon sees only the published event');
select pg_temp.ok((select count(*) from public.ticket_types) = 2, 'anon sees only ticket types of published events');
select pg_temp.ok(pg_temp.err('select capacity from public.events') like 'permission denied%', 'anon cannot read capacity');
select pg_temp.ok(pg_temp.err('select allocation from public.ticket_types') like 'permission denied%', 'anon cannot read allocation');
select pg_temp.ok(pg_temp.err('select * from public.orders') like 'permission denied%', 'anon cannot read orders');
select pg_temp.ok(pg_temp.err('select * from public.tickets') like 'permission denied%', 'anon cannot read tickets');
select pg_temp.ok(pg_temp.err('select * from public.payment_events') like 'permission denied%', 'anon cannot read payment events');
select pg_temp.ok(pg_temp.err($$update public.events set name = 'x'$$) like 'permission denied%', 'anon cannot edit events');
select pg_temp.ok(pg_temp.err($$insert into public.tickets (order_id, event_id, ticket_type_id) values (gen_random_uuid(), gen_random_uuid(), gen_random_uuid())$$) like 'permission denied%', 'anon cannot create tickets');
select pg_temp.ok(pg_temp.err($$select public.reserve_tickets('20000000-0000-0000-0000-000000000001', 1, repeat('a', 64), null)$$) like 'permission denied%', 'anon cannot reserve directly');
select pg_temp.ok(pg_temp.err($$select public.confirm_payment('x','e','t',gen_random_uuid(),'p',1,'gbp','a@b.c')$$) like 'permission denied%', 'anon cannot confirm payments');
select pg_temp.ok(pg_temp.err($$select public.check_in_ticket(gen_random_uuid(), gen_random_uuid(), gen_random_uuid())$$) like 'permission denied%', 'anon cannot check in');
reset role;

set role authenticated;
set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000b';
select pg_temp.ok((select count(*) from public.staff) = 0, 'a non-staff user sees no staff rows');
select pg_temp.ok(pg_temp.err('select * from public.orders') like 'permission denied%', 'signed-in user cannot read orders');
select pg_temp.ok(pg_temp.err($$update public.orders set status = 'paid'$$) like 'permission denied%', 'signed-in user cannot mark orders paid');
select pg_temp.ok(pg_temp.err($$insert into public.staff (user_id) values ('00000000-0000-0000-0000-00000000000b')$$) like 'permission denied%', 'signed-in user cannot make themselves staff');
set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000a';
select pg_temp.ok((select count(*) from public.staff) = 1, 'a staff user sees their own staff row');
reset role;

-- ---------------------------------------------------------------- reserving (service role)
set role service_role;

select (public.reserve_tickets('20000000-0000-0000-0000-000000000001', 3, repeat('1', 64), 'ip1'))->>'order_id' as o1 \gset
select pg_temp.ok((select amount_pence from public.orders where id = :'o1') = 4500, 'price comes from the database: 3 x 1500 = 4500');
select pg_temp.ok(pg_temp.err($$select public.reserve_tickets('20000000-0000-0000-0000-000000000001', 1, 'not-a-hash', null)$$) like '%violates check constraint%', 'access token hash must be a sha256 hex');
select pg_temp.ok(pg_temp.err($$select public.reserve_tickets('20000000-0000-0000-0000-000000000001', 2, repeat('2', 64), null)$$) = 'sold_out', 'ticket type allocation is enforced');
select pg_temp.ok(pg_temp.err($$select public.reserve_tickets('20000000-0000-0000-0000-000000000002', 3, repeat('2', 64), null)$$) = 'sold_out', 'event capacity is enforced across ticket types');
select (public.reserve_tickets('20000000-0000-0000-0000-000000000002', 2, repeat('2', 64), 'ip2'))->>'order_id' as o2 \gset
select pg_temp.ok(pg_temp.err($$select public.reserve_tickets('20000000-0000-0000-0000-000000000002', 1, repeat('3', 64), null)$$) = 'sold_out', 'event is now full');
select pg_temp.ok(pg_temp.err($$select public.reserve_tickets('20000000-0000-0000-0000-000000000002', 0, repeat('3', 64), null)$$) = 'invalid_quantity', 'quantity 0 rejected');
select pg_temp.ok(pg_temp.err($$select public.reserve_tickets('20000000-0000-0000-0000-000000000002', 5, repeat('3', 64), null)$$) = 'invalid_quantity', 'quantity above max per order rejected');
select pg_temp.ok(pg_temp.err($$select public.reserve_tickets('20000000-0000-0000-0000-000000000003', 1, repeat('3', 64), null)$$) = 'not_on_sale', 'draft event cannot be bought');
select pg_temp.ok(pg_temp.err($$select public.reserve_tickets(gen_random_uuid(), 1, repeat('3', 64), null)$$) = 'not_on_sale', 'unknown ticket type rejected');

select pg_temp.ok(
  (select bool_and(t->>'sale_state' = 'sold_out') from jsonb_array_elements(public.public_event_listing()->0->'ticket_types') t),
  'listing shows both ticket types sold out while holds are live');
select pg_temp.ok(jsonb_array_length(public.public_event_listing()) = 1, 'listing hides draft events');

-- ---------------------------------------------------------------- paying
select pg_temp.ok(public.attach_checkout(:'o1', 'testpay', 'chk_1'), 'checkout attached to pending order');
select pg_temp.ok(not public.attach_checkout(:'o1', 'testpay', 'chk_other'), 'checkout cannot be re-attached');

select pg_temp.ok((public.confirm_payment('testpay', 'evt_1', 'paid', :'o1', 'pay_1', 4500, 'GBP', 'Buyer@Example.com'))->>'outcome' = 'fulfilled', 'payment confirmed and fulfilled');
select pg_temp.ok((select count(*) from public.tickets where order_id = :'o1') = 3, 'three tickets issued');
select pg_temp.ok((select email from public.orders where id = :'o1') = 'buyer@example.com', 'email stored lower-case');
select pg_temp.ok((public.confirm_payment('testpay', 'evt_1', 'paid', :'o1', 'pay_1', 4500, 'gbp', 'buyer@example.com'))->>'outcome' = 'duplicate', 'same notification twice is ignored');
select pg_temp.ok((public.confirm_payment('testpay', 'evt_1b', 'paid', :'o1', 'pay_1', 4500, 'gbp', 'buyer@example.com'))->>'outcome' = 'already_paid', 'same payment under a new event id is ignored');
select pg_temp.ok((public.confirm_payment('testpay', 'evt_1c', 'paid', :'o1', 'pay_9', 4500, 'gbp', 'buyer@example.com'))->>'outcome' = 'second_payment_needs_refund', 'a second, different payment is flagged');
select pg_temp.ok((select count(*) from public.tickets where order_id = :'o1') = 3, 'still exactly three tickets');

select public.attach_checkout(:'o2', 'testpay', 'chk_2') \gset ignored_
select pg_temp.ok((public.confirm_payment('testpay', 'evt_2', 'paid', :'o2', 'pay_2', 100, 'gbp', 'x@example.com'))->>'outcome' = 'amount_mismatch', 'underpayment is caught');
select pg_temp.ok((select status from public.orders where id = :'o2') = 'review', 'underpaid order goes to review');
select pg_temp.ok((select count(*) from public.tickets where order_id = :'o2') = 0, 'no tickets for underpaid order');
select pg_temp.ok((public.confirm_payment('otherpay', 'evt_x', 'paid', gen_random_uuid(), 'p', 1, 'gbp', null))->>'outcome' = 'order_not_found', 'unknown order is logged, not fulfilled');
reset role;

-- ---------------------------------------------------------------- holds expiring
-- Free the review order's seats and add capacity so hold behaviour can be tested.
update public.orders set status = 'cancelled' where id = :'o2';
update public.events set capacity = 6 where id = '10000000-0000-0000-0000-000000000001';

set role service_role;
select (public.reserve_tickets('20000000-0000-0000-0000-000000000002', 3, repeat('4', 64), null))->>'order_id' as o3 \gset
select public.attach_checkout(:'o3', 'testpay', 'chk_3') \gset ignored_
select pg_temp.ok(pg_temp.err($$select public.reserve_tickets('20000000-0000-0000-0000-000000000002', 1, repeat('5', 64), null)$$) = 'sold_out', 'held seats are not sellable');
reset role;
update public.orders set hold_expires_at = now() - interval '1 minute' where id = :'o3';
set role service_role;
select (public.reserve_tickets('20000000-0000-0000-0000-000000000002', 3, repeat('5', 64), null))->>'order_id' as o4 \gset
select pg_temp.ok(:'o4' is not null, 'seats from an expired hold can be sold again');
select pg_temp.ok((public.confirm_payment('testpay', 'evt_3', 'paid', :'o3', 'pay_3', 9000, 'gbp', 'late@example.com'))->>'outcome' = 'no_capacity_needs_refund', 'late payment that would oversell is flagged, not fulfilled');
select pg_temp.ok((select count(*) from public.tickets where order_id = :'o3') = 0, 'no tickets oversold');

select public.attach_checkout(:'o4', 'testpay', 'chk_4') \gset ignored_
select pg_temp.ok((public.release_order('testpay', 'evt_4x', 'expired', :'o4'))->>'outcome' = 'released', 'abandoned checkout releases the hold');
select pg_temp.ok((public.release_order('testpay', 'evt_4x', 'expired', :'o4'))->>'outcome' = 'duplicate', 'release notification is idempotent');
select pg_temp.ok((public.confirm_payment('testpay', 'evt_4', 'paid', :'o4', 'pay_4', 9000, 'gbp', 'late2@example.com'))->>'outcome' = 'fulfilled_late', 'late payment with seats free is honoured');
select pg_temp.ok((select count(*) from public.tickets where order_id = :'o4') = 3, 'late payment gets its tickets');

-- ---------------------------------------------------------------- buyer ticket page
select pg_temp.ok(public.get_order(:'o1', repeat('0', 64)) is null, 'wrong link secret shows nothing');
select pg_temp.ok(jsonb_array_length(public.get_order(:'o1', repeat('1', 64))->'tickets') = 3, 'right link secret shows the tickets');
select pg_temp.ok(jsonb_array_length(public.get_order(:'o3', repeat('4', 64))->'tickets') = 0, 'unpaid order shows no tickets');

-- ---------------------------------------------------------------- refunds
select pg_temp.ok((public.refund_order('testpay', 'evt_r0', 'refund', 'pay_4', false))->>'outcome' = 'partial_refund_logged', 'partial refund only logged');
select pg_temp.ok((public.refund_order('testpay', 'evt_r1', 'refund', 'pay_4', true))->>'outcome' = 'refunded', 'full refund processed');
select pg_temp.ok((public.refund_order('testpay', 'evt_r1', 'refund', 'pay_4', true))->>'outcome' = 'duplicate', 'refund notification is idempotent');
select pg_temp.ok((select count(*) from public.tickets where order_id = :'o4' and status = 'cancelled') = 3, 'refunded tickets are cancelled');

-- ---------------------------------------------------------------- door check-in
select id as t1 from public.tickets where order_id = :'o1' order by id limit 1 \gset
select id as t4 from public.tickets where order_id = :'o4' order by id limit 1 \gset
\set ev '10000000-0000-0000-0000-000000000001'
\set staff '00000000-0000-0000-0000-00000000000a'
select pg_temp.ok(pg_temp.err(format('select public.check_in_ticket(%L, %L, %L)', :'t1', :'ev', '00000000-0000-0000-0000-00000000000b')) = 'not_staff', 'non-staff cannot check in');
select pg_temp.ok((public.check_in_ticket(:'t1', '10000000-0000-0000-0000-000000000002', :'staff'))->>'result' = 'wrong_event', 'ticket for another event rejected');
select pg_temp.ok((public.check_in_ticket(:'t1', :'ev', :'staff'))->>'result' = 'valid', 'first scan is valid');
select pg_temp.ok((public.check_in_ticket(:'t1', :'ev', :'staff'))->>'result' = 'already_used', 'second scan says already used');
select pg_temp.ok((public.check_in_ticket(:'t4', :'ev', :'staff'))->>'result' = 'cancelled', 'refunded ticket rejected');
select pg_temp.ok((public.check_in_ticket(gen_random_uuid(), :'ev', :'staff'))->>'result' = 'not_found', 'unknown ticket rejected');
select pg_temp.ok((public.check_in_ticket(null, :'ev', :'staff'))->>'result' = 'invalid_code', 'forged code logged as invalid');
select pg_temp.ok((select count(*) from public.checkin_attempts) = 6, 'every scan attempt is logged');
select pg_temp.ok((public.refund_order('testpay', 'evt_r2', 'refund', 'pay_1', true))->>'outcome' = 'refunded', 'refund of partly used order');
select pg_temp.ok((select status from public.tickets where id = :'t1') = 'used', 'a used ticket stays used after refund');

-- ---------------------------------------------------------------- rate limiting
select pg_temp.ok(public.hit_rate_limit('t:a', 60, 3) and public.hit_rate_limit('t:a', 60, 3) and public.hit_rate_limit('t:a', 60, 3), 'first three calls allowed');
select pg_temp.ok(not public.hit_rate_limit('t:a', 60, 3), 'fourth call blocked');
select pg_temp.ok(public.hit_rate_limit('t:b', 60, 3), 'other keys unaffected');
reset role;

\echo ALL TESTS PASSED
