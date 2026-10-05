#!/usr/bin/env bash
# Concurrency tests: two buyers racing for the last seat, and two scanners racing on one ticket.
# Usage: PSQL="psql -h HOST -p PORT -U postgres" tests/race_test.sh   (needs a throwaway server)
set -euo pipefail
cd "$(dirname "$0")"
P="${PSQL:?set PSQL} -X -q -t -A -v ON_ERROR_STOP=1"
$P -c 'drop database if exists race' -c 'create database race'
R="$P -d race"
$R -f local_stub.sql -f ../migrations/20261005122332_ticketing_core.sql -f ../migrations/20261005122415_ticketing_fk_indexes.sql -f ../migrations/20261005124811_ticket_emails.sql -f ../migrations/20261005124923_retire_old_reserve_tickets.sql -f ../migrations/20261005125548_normalise_order_email.sql >/dev/null
$R <<'SQL'
insert into auth.users (id) values ('00000000-0000-0000-0000-00000000000a');
insert into public.staff (user_id) values ('00000000-0000-0000-0000-00000000000a');
insert into public.events (id, name, kind, venue, address, doors_at, ends_at, capacity, status) values
  ('10000000-0000-0000-0000-000000000001', 'Race', 'club', 'v', 'a', now() + interval '1 day', now() + interval '2 days', 1, 'published');
insert into public.ticket_types (id, event_id, name, price_pence, allocation) values
  ('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'GA', 1000, 10);
SQL

TT=20000000-0000-0000-0000-000000000001
reserve() { # $1 = hash digit, $2 = seconds to hold the transaction open
  $R -c "begin; set role service_role;
         select coalesce((select 'reserved' from (select public.reserve_tickets(gen_random_uuid(), '$TT', 1, repeat('$1', 64), null)) x), 'reserved');
         select pg_sleep($2); commit;" 2>&1 | grep -v "^$" | head -1 || true
}
reserve 1 2 > a.out & sleep 0.5; reserve 2 0 > b.out; wait
A=$(cat a.out); B=$(cat b.out); rm -f a.out b.out
echo "buyer A: $A | buyer B: $B"
[[ "$A" == reserved && "$B" == *sold_out* ]] || { echo "FAIL: last seat race"; exit 1; }
echo "ok - only one buyer gets the last seat"

# Issue one paid ticket, then scan it from two devices at the same moment.
TICKET=$($R -c "set role service_role;
  select public.attach_checkout(id, 'p', 'c') from public.orders limit 1;" >/dev/null; $R -c "set role service_role;
  select public.confirm_payment('p', 'e1', 'paid', id, 'pay', 1000, 'gbp', 'a@b.c') from public.orders limit 1;" >/dev/null; $R -c "select id from public.tickets limit 1")
EV=10000000-0000-0000-0000-000000000001; ST=00000000-0000-0000-0000-00000000000a
scan() {
  $R -c "begin; set role service_role;
         select public.check_in_ticket('$TICKET', '$EV', '$ST')->>'result';
         select pg_sleep($1); commit;" | grep -v '^$' | head -1
}
scan 2 > a.out & sleep 0.5; scan 0 > b.out; wait
A=$(cat a.out); B=$(cat b.out); rm -f a.out b.out
echo "scanner A: $A | scanner B: $B"
[[ "$A" == valid && "$B" == already_used ]] || { echo "FAIL: double scan race"; exit 1; }
echo "ok - a ticket scanned on two devices at once gets in only once"
echo RACE TESTS PASSED
