#!/usr/bin/env bash
# Runs the database behaviour and race tests against a throwaway Postgres (never a Supabase project).
# Usage: PSQL="psql -h localhost -p 5432 -U postgres" supabase/tests/run.sh
set -euo pipefail
cd "$(dirname "$0")"
P="${PSQL:?set PSQL to a psql command for a throwaway server} -X -q -t -v ON_ERROR_STOP=1"
$P -c 'drop database if exists pa_test' -c 'create database pa_test' >/dev/null
$P -d pa_test -f local_stub.sql \
  -f ../migrations/20261005122332_ticketing_core.sql \
  -f ../migrations/20261005122415_ticketing_fk_indexes.sql \
  -f ../migrations/20261005124811_ticket_emails.sql -f ../migrations/20261005124923_retire_old_reserve_tickets.sql -f ../migrations/20261005125548_normalise_order_email.sql -f ../migrations/20261005130213_review_fixes.sql \
  -f ticketing_test.sql 2>&1 | sed -n 's/.*NOTICE:  //p; /ALL TESTS PASSED/p; /ERROR/p'
./race_test.sh 2>&1 | grep -v NOTICE
