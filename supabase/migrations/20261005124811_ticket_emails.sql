-- Ticket emails.
--
-- * Order ids are now created by the checkout function, so the buyer's private link secret can be
--   derived from the order id with TICKET_SIGNING_SECRET instead of being stored or sent through
--   the payment provider. That lets the ticket email carry the link at any time later.
-- * email_outbox is an outbox: confirm_payment queues the tickets email in the same transaction
--   that issues the tickets, so a paid order can never end up without a queued email.
-- * Edge Functions claim due emails (skip-locked, so parallel senders never double send),
--   then mark each one sent or failed. Failures retry with backoff, then stop after 6 attempts.

-- ---------------------------------------------------------------------------
-- reserve_tickets takes the order id from the caller
-- (the old signature is dropped in the next migration)
-- ---------------------------------------------------------------------------
create function public.reserve_tickets(
  p_order_id           uuid,
  p_ticket_type_id     uuid,
  p_quantity           integer,
  p_access_token_hash  text,
  p_client_key         text,
  p_hold_minutes       integer default 35
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_tt    public.ticket_types%rowtype;
  v_ev    public.events%rowtype;
  v_order public.orders%rowtype;
begin
  if p_order_id is null then
    raise exception 'invalid_order_id' using errcode = '22023';
  end if;
  if p_hold_minutes is null or p_hold_minutes < 5 or p_hold_minutes > 120 then
    raise exception 'invalid_hold' using errcode = '22023';
  end if;

  select * into v_tt from public.ticket_types where id = p_ticket_type_id;
  if not found then
    raise exception 'not_on_sale' using errcode = 'P0001';
  end if;

  select * into v_ev from public.events where id = v_tt.event_id for update;

  if v_ev.status <> 'published' or not v_tt.is_active or now() >= v_ev.ends_at
     or (v_tt.sales_start is not null and now() < v_tt.sales_start)
     or (v_tt.sales_end is not null and now() >= v_tt.sales_end) then
    raise exception 'not_on_sale' using errcode = 'P0001';
  end if;

  if p_quantity is null or p_quantity < 1 or p_quantity > v_tt.max_per_order then
    raise exception 'invalid_quantity' using errcode = '22023';
  end if;

  if v_tt.allocation - public.ticket_type_taken(v_tt.id) < p_quantity
     or v_ev.capacity - public.event_taken(v_ev.id) < p_quantity then
    raise exception 'sold_out' using errcode = 'P0001';
  end if;

  insert into public.orders (
    id, event_id, ticket_type_id, quantity, unit_price_pence, amount_pence, currency,
    hold_expires_at, access_token_hash, client_key
  ) values (
    p_order_id, v_ev.id, v_tt.id, p_quantity, v_tt.price_pence, v_tt.price_pence * p_quantity, v_tt.currency,
    now() + make_interval(mins => p_hold_minutes), p_access_token_hash, p_client_key
  ) returning * into v_order;

  return jsonb_build_object(
    'order_id', v_order.id,
    'quantity', v_order.quantity,
    'unit_price_pence', v_order.unit_price_pence,
    'amount_pence', v_order.amount_pence,
    'currency', v_order.currency,
    'hold_expires_at', v_order.hold_expires_at,
    'ticket_name', v_tt.name,
    'event_name', v_ev.name
  );
end $$;

-- ---------------------------------------------------------------------------
-- Outbox
-- ---------------------------------------------------------------------------
create type public.email_status as enum ('pending', 'sending', 'sent', 'failed');

create table public.email_outbox (
  id                   uuid primary key default gen_random_uuid(),
  order_id             uuid not null references public.orders (id) on delete cascade,
  kind                 text not null check (kind in ('tickets', 'resend')),
  to_email             text not null,
  status               public.email_status not null default 'pending',
  attempts             integer not null default 0,
  next_attempt_at      timestamptz not null default now(),
  provider_message_id  text,
  last_error           text,
  created_at           timestamptz not null default now(),
  sent_at              timestamptz
);
-- Exactly one "your tickets" email per order, however many times payment is confirmed.
create unique index email_outbox_one_tickets_email on public.email_outbox (order_id) where kind = 'tickets';
create index email_outbox_due_idx on public.email_outbox (status, next_attempt_at);
create index email_outbox_order_idx on public.email_outbox (order_id);

alter table public.email_outbox enable row level security;
revoke all on public.email_outbox from anon, authenticated;

-- ---------------------------------------------------------------------------
-- confirm_payment: same as before, plus queueing the tickets email when tickets are issued
-- ---------------------------------------------------------------------------
create or replace function public.confirm_payment(
  p_provider          text,
  p_provider_event_id text,
  p_event_type        text,
  p_order_id          uuid,
  p_payment_id        text,
  p_amount_pence      integer,
  p_currency          text,
  p_email             text
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_pe_id    bigint;
  v_order    public.orders%rowtype;
  v_ev       public.events%rowtype;
  v_tt       public.ticket_types%rowtype;
  v_outcome  text;
  v_late     boolean;
begin
  insert into public.payment_events (provider, provider_event_id, event_type, order_id)
  values (p_provider, p_provider_event_id, p_event_type, null)
  on conflict (provider, provider_event_id) do nothing
  returning id into v_pe_id;

  if v_pe_id is null then
    return jsonb_build_object('outcome', 'duplicate');
  end if;

  select * into v_order from public.orders where id = p_order_id for update;

  if not found then
    v_outcome := 'order_not_found';

  elsif v_order.status = 'paid' then
    v_outcome := case when v_order.provider_payment_id = p_payment_id
                      then 'already_paid' else 'second_payment_needs_refund' end;

  elsif v_order.status in ('refunded', 'review') then
    v_outcome := 'order_not_payable_needs_review';

  elsif v_order.provider is distinct from p_provider
        or p_amount_pence is distinct from v_order.amount_pence
        or lower(p_currency) is distinct from v_order.currency then
    update public.orders
       set status = 'review', review_reason = 'amount_or_provider_mismatch',
           provider_payment_id = p_payment_id, email = lower(p_email)
     where id = v_order.id;
    v_outcome := 'amount_mismatch';

  else
    v_late := v_order.status <> 'pending' or v_order.hold_expires_at <= now();

    if v_late then
      select * into v_ev from public.events where id = v_order.event_id for update;
      select * into v_tt from public.ticket_types where id = v_order.ticket_type_id;
    end if;

    if v_late and (v_tt.allocation - public.ticket_type_taken(v_tt.id) < v_order.quantity
                   or v_ev.capacity - public.event_taken(v_ev.id) < v_order.quantity) then
      update public.orders
         set status = 'review', review_reason = 'paid_after_hold_expired_no_capacity',
             provider_payment_id = p_payment_id, email = lower(p_email)
       where id = v_order.id;
      v_outcome := 'no_capacity_needs_refund';
    else
      update public.orders
         set status = 'paid', paid_at = now(),
             provider_payment_id = p_payment_id, email = lower(p_email)
       where id = v_order.id;

      insert into public.tickets (order_id, event_id, ticket_type_id)
      select v_order.id, v_order.event_id, v_order.ticket_type_id
      from generate_series(1, v_order.quantity);

      if nullif(trim(p_email), '') is not null then
        insert into public.email_outbox (order_id, kind, to_email)
        values (v_order.id, 'tickets', lower(trim(p_email)))
        on conflict do nothing;
      end if;

      v_outcome := case when v_late then 'fulfilled_late' else 'fulfilled' end;
    end if;
  end if;

  update public.payment_events
     set outcome = v_outcome, order_id = v_order.id
   where id = v_pe_id;

  return jsonb_build_object('outcome', v_outcome, 'order_id', v_order.id);
end $$;

-- ---------------------------------------------------------------------------
-- Sending
-- ---------------------------------------------------------------------------

-- Claim up to p_limit due emails. A claim lasts 5 minutes; an email whose sender crashed
-- becomes due again after that.
create function public.claim_emails(p_limit integer) returns jsonb
language sql security definer set search_path = '' as $$
  with due as (
    select id from public.email_outbox
    where status in ('pending', 'sending') and next_attempt_at <= now()
    order by created_at
    limit greatest(1, least(p_limit, 50))
    for update skip locked
  ), claimed as (
    update public.email_outbox o
       set status = 'sending', attempts = o.attempts + 1,
           next_attempt_at = now() + interval '5 minutes'
      from due where o.id = due.id
    returning o.id, o.order_id, o.kind, o.to_email, o.attempts
  )
  select coalesce(jsonb_agg(to_jsonb(claimed)), '[]'::jsonb) from claimed;
$$;

-- What goes in the email. Only paid orders get one.
create function public.order_email_details(p_order_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'order_id', o.id, 'status', o.status, 'quantity', o.quantity,
    'amount_pence', o.amount_pence, 'currency', o.currency,
    'ticket_name', t.name,
    'event', jsonb_build_object('name', e.name, 'venue', e.venue, 'address', e.address,
                                'doors_at', e.doors_at, 'ends_at', e.ends_at, 'min_age', e.min_age)
  )
  from public.orders o
  join public.events e on e.id = o.event_id
  join public.ticket_types t on t.id = o.ticket_type_id
  where o.id = p_order_id;
$$;

create function public.mark_email_sent(p_email_id uuid, p_provider_message_id text) returns void
language sql security definer set search_path = '' as $$
  update public.email_outbox
     set status = 'sent', sent_at = now(), provider_message_id = p_provider_message_id, last_error = null
   where id = p_email_id and status = 'sending';
$$;

-- Retries after 2, 4, 8, 16, 32 minutes, then gives up. p_permanent skips retries.
create function public.mark_email_failed(p_email_id uuid, p_error text, p_permanent boolean default false)
returns void
language sql security definer set search_path = '' as $$
  update public.email_outbox
     set status = case when p_permanent or attempts >= 6 then 'failed'::public.email_status
                       else 'pending'::public.email_status end,
         next_attempt_at = now() + make_interval(mins => power(2, least(attempts, 6))::integer),
         last_error = left(p_error, 500)
   where id = p_email_id and status = 'sending';
$$;

-- "Find my tickets": queue a re-send for each paid order on this address whose event hasn't
-- finished. At most one re-send per order every 10 minutes. Returns how many were queued, which
-- the Edge Function never reveals to the caller.
create function public.request_ticket_resend(p_email text) returns integer
language plpgsql security definer set search_path = '' as $$
declare
  v_count integer;
begin
  insert into public.email_outbox (order_id, kind, to_email)
  select o.id, 'resend', o.email
  from public.orders o
  join public.events e on e.id = o.event_id
  where o.email = lower(trim(p_email))
    and o.status = 'paid'
    and e.ends_at > now()
    and not exists (
      select 1 from public.email_outbox x
      where x.order_id = o.id and x.kind = 'resend' and x.created_at > now() - interval '10 minutes'
    );
  get diagnostics v_count = row_count;
  return v_count;
end $$;

revoke execute on function
  public.reserve_tickets(uuid, uuid, integer, text, text, integer),
  public.confirm_payment(text, text, text, uuid, text, integer, text, text),
  public.claim_emails(integer),
  public.order_email_details(uuid),
  public.mark_email_sent(uuid, text),
  public.mark_email_failed(uuid, text, boolean),
  public.request_ticket_resend(text)
from public, anon, authenticated;

grant execute on function
  public.reserve_tickets(uuid, uuid, integer, text, text, integer),
  public.confirm_payment(text, text, text, uuid, text, integer, text, text),
  public.claim_emails(integer),
  public.order_email_details(uuid),
  public.mark_email_sent(uuid, text),
  public.mark_email_failed(uuid, text, boolean),
  public.request_ticket_resend(text)
to service_role;
