#!/usr/bin/env bash
# Concurrency tests, using two real database sessions:
#  1. two buyers racing for the last seat
#  2. a ticket scanned on two devices at the same moment
#  3. a payment confirmed just as its hold expires, while someone else buys the freed seat
# Usage: PSQL="psql -h HOST -p PORT -U postgres" tests/race_test.sh   (needs a throwaway server)
set -euo pipefail
cd "$(dirname "$0")"
P="${PSQL:?set PSQL} -X -q -t -A -v ON_ERROR_STOP=1"
$P -c 'drop database if exists race' -c 'create database race' >/dev/null
R="$P -d race"
$R -f local_stub.sql -f ../migrations/20261005122332_ticketing_core.sql -f ../migrations/20261005122415_ticketing_fk_indexes.sql \
   -f ../migrations/20261005124811_ticket_emails.sql -f ../migrations/20261005124923_retire_old_reserve_tickets.sql \
   -f ../migrations/20261005125548_normalise_order_email.sql -f ../migrations/20261005130213_review_fixes.sql >/dev/null
$R <<'SQL'
insert into auth.users (id) values ('00000000-0000-0000-0000-00000000000a');
insert into public.staff (user_id) values ('00000000-0000-0000-0000-00000000000a');
insert into public.events (id, name, kind, venue, address, doors_at, ends_at, capacity, status) values
  ('10000000-0000-0000-0000-000000000001', 'Race', 'club', 'v', 'a', now() + interval '1 day', now() + interval '2 days', 1, 'published'),
  ('10000000-0000-0000-0000-000000000002', 'Late', 'club', 'v', 'a', now() + interval '1 day', now() + interval '2 days', 1, 'published');
insert into public.ticket_types (id, event_id, name, price_pence, allocation) values
  ('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'GA', 1000, 10),
  ('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002', 'GA', 1000, 10);
SQL

# Wait until session A is inside its pg_sleep, i.e. it already holds whatever lock it took.
wait_for_sleeper() {
  for _ in $(seq 1 200); do
    [ "$($R -c "select count(*) from pg_stat_activity where datname = 'race' and wait_event = 'PgSleep'")" = 1 ] && return 0
    sleep 0.05
  done
  echo "FAIL: session A never started"; exit 1
}

# 1. Last seat
TT=20000000-0000-0000-0000-000000000001
reserve() { # $1 = hash digit, $2 = seconds to hold the transaction open
  $R -c "begin; set role service_role;
         select 'reserved' from (select public.reserve_tickets(gen_random_uuid(), '$TT', 1, repeat('$1', 64), null)) x;
         select pg_sleep($2); commit;" 2>&1 | grep -v "^$" | head -1 || true
}
reserve 1 2 > a.out & wait_for_sleeper; reserve 2 0 > b.out; wait
A=$(cat a.out); B=$(cat b.out); rm -f a.out b.out
echo "buyer A: $A | buyer B: $B"
[[ "$A" == reserved && "$B" == *sold_out* ]] || { echo "FAIL: last seat race"; exit 1; }
echo "ok - only one buyer gets the last seat"

# 2. Double scan
$R -c "set role service_role; select public.attach_checkout(id, 'p', 'c') from public.orders where ticket_type_id = '$TT';" >/dev/null
$R -c "set role service_role; select public.confirm_payment('p', 'e1', 'paid', id, 'pay', 1000, 'gbp', 'a@b.c') from public.orders where ticket_type_id = '$TT';" >/dev/null
TICKET=$($R -c "select id from public.tickets limit 1")
EV=10000000-0000-0000-0000-000000000001; ST=00000000-0000-0000-0000-00000000000a
scan() {
  $R -c "begin; set role service_role;
         select public.check_in_ticket('$TICKET', '$EV', '$ST')->>'result';
         select pg_sleep($1); commit;" | grep -v '^$' | head -1
}
scan 2 > a.out & wait_for_sleeper; scan 0 > b.out; wait
A=$(cat a.out); B=$(cat b.out); rm -f a.out b.out
echo "scanner A: $A | scanner B: $B"
[[ "$A" == valid && "$B" == already_used ]] || { echo "FAIL: double scan race"; exit 1; }
echo "ok - a ticket scanned on two devices at once gets in only once"

# 3. Payment confirmed as its hold expires. Order X holds the only seat for 1 more second.
#    Session A starts its transaction before the hold ends and confirms after it ends; meanwhile
#    buyer B takes the freed seat. Exactly one of them may end up with it.
LT=20000000-0000-0000-0000-000000000002
X=$($R -c "set role service_role; select public.reserve_tickets(gen_random_uuid(), '$LT', 1, repeat('7', 64), null)->>'order_id'")
$R -c "set role service_role; select public.attach_checkout('$X', 'p', 'cx');" >/dev/null
$R -c "update public.orders set hold_expires_at = clock_timestamp() + interval '1 second' where id = '$X'"
$R -c "begin; set role service_role; select now();
       select pg_sleep(2.5);
       select public.confirm_payment('p', 'ex', 'paid', '$X', 'payx', 1000, 'gbp', 'x@b.c')->>'outcome'; commit;" \
  | grep -v '^$' | tail -1 > a.out &
wait_for_sleeper
until [ "$($R -c "select clock_timestamp() > hold_expires_at from public.orders where id = '$X'")" = t ]; do sleep 0.05; done
B=$($R -c "set role service_role; select 'reserved' from (select public.reserve_tickets(gen_random_uuid(), '$LT', 1, repeat('8', 64), null)) x" 2>&1 | grep -v '^$' | head -1 || true)
wait; A=$(cat a.out); rm -f a.out
SOLD=$($R -c "select count(*) from public.orders where ticket_type_id = '$LT' and (status = 'paid' or (status = 'pending' and hold_expires_at > clock_timestamp()))")
echo "late payment: $A | new buyer: $B | seats taken: $SOLD of 1"
[[ "$B" == reserved && "$A" == no_capacity_needs_refund && "$SOLD" == 1 ]] || { echo "FAIL: late payment race"; exit 1; }
echo "ok - a payment landing as its hold expires can't oversell"
echo RACE TESTS PASSED
