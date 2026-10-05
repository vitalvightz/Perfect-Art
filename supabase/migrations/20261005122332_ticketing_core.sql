-- Perfect Art ticketing core. Works with any payment provider.
--
-- Security model
--   * The browser (anon / authenticated) can only read published events and their active
--     ticket types, and a signed-in staff member can read their own staff row. Nothing else.
--   * Every write, and every read of orders, tickets and payments, goes through Edge Functions
--     that call the SECURITY DEFINER functions below with the service role.
--   * Those functions can be executed by service_role only. The browser can never mark an
--     order paid, create a ticket or check one in.
--   * Prices always come from ticket_types. The client only ever sends a ticket type and a
--     quantity. Money is stored as integer pence.

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------
create type public.event_status as enum ('draft', 'published', 'cancelled');
create type public.event_kind as enum ('club', 'bar');
create type public.order_status as enum ('pending', 'paid', 'expired', 'cancelled', 'refunded', 'review');
create type public.ticket_status as enum ('active', 'used', 'cancelled');
create type public.staff_role as enum ('staff', 'admin');

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------
create table public.events (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (length(name) between 1 and 120),
  kind        public.event_kind not null,
  venue       text not null,
  address     text not null,
  doors_at    timestamptz not null,
  ends_at     timestamptz not null,
  capacity    integer not null check (capacity > 0),
  min_age     integer not null default 18 check (min_age between 0 and 25),
  status      public.event_status not null default 'draft',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  check (ends_at > doors_at)
);

create table public.ticket_types (
  id             uuid primary key default gen_random_uuid(),
  event_id       uuid not null references public.events (id) on delete restrict,
  name           text not null check (length(name) between 1 and 80),
  perks          text[] not null default '{}',
  price_pence    integer not null check (price_pence > 0),
  currency       text not null default 'gbp' check (currency ~ '^[a-z]{3}$'),
  allocation     integer not null check (allocation > 0),
  max_per_order  integer not null default 10 check (max_per_order between 1 and 20),
  sales_start    timestamptz,
  sales_end      timestamptz,
  is_active      boolean not null default true,
  sort_order     integer not null default 0,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  check (sales_end is null or sales_start is null or sales_end > sales_start)
);
create index ticket_types_event_id_idx on public.ticket_types (event_id);

create table public.orders (
  id                   uuid primary key default gen_random_uuid(),
  event_id             uuid not null references public.events (id) on delete restrict,
  ticket_type_id       uuid not null references public.ticket_types (id) on delete restrict,
  quantity             integer not null check (quantity between 1 and 20),
  unit_price_pence     integer not null check (unit_price_pence > 0),
  amount_pence         integer not null,
  currency             text not null check (currency ~ '^[a-z]{3}$'),
  status               public.order_status not null default 'pending',
  hold_expires_at      timestamptz not null,
  -- SHA-256 (hex) of the secret in the buyer's ticket link. The secret itself is never stored.
  access_token_hash    text not null unique check (access_token_hash ~ '^[0-9a-f]{64}$'),
  email                text,
  provider             text,
  provider_checkout_id text,
  provider_payment_id  text,
  -- Keyed hash of the buyer's IP, kept only for abuse investigation.
  client_key           text,
  review_reason        text,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  paid_at              timestamptz,
  check (amount_pence = unit_price_pence * quantity),
  unique (provider, provider_checkout_id),
  unique (provider, provider_payment_id)
);
create index orders_ticket_type_status_idx on public.orders (ticket_type_id, status);
create index orders_event_status_idx on public.orders (event_id, status);

create table public.tickets (
  id              uuid primary key default gen_random_uuid(),
  order_id        uuid not null references public.orders (id) on delete restrict,
  event_id        uuid not null references public.events (id) on delete restrict,
  ticket_type_id  uuid not null references public.ticket_types (id) on delete restrict,
  status          public.ticket_status not null default 'active',
  checked_in_at   timestamptz,
  checked_in_by   uuid references auth.users (id) on delete set null,
  created_at      timestamptz not null default now(),
  check ((status = 'used') = (checked_in_at is not null))
);
create index tickets_order_id_idx on public.tickets (order_id);
create index tickets_event_id_idx on public.tickets (event_id);

-- One row per provider notification. The unique key is what makes payment handling
-- idempotent: a notification that arrives twice is only ever processed once.
create table public.payment_events (
  id                 bigint generated always as identity primary key,
  provider           text not null,
  provider_event_id  text not null,
  event_type         text not null,
  order_id           uuid references public.orders (id) on delete set null,
  outcome            text,
  received_at        timestamptz not null default now(),
  unique (provider, provider_event_id)
);

create table public.staff (
  user_id     uuid primary key references auth.users (id) on delete cascade,
  role        public.staff_role not null default 'staff',
  created_at  timestamptz not null default now()
);

create table public.checkin_attempts (
  id             bigint generated always as identity primary key,
  ticket_id      uuid,
  event_id       uuid,
  staff_user_id  uuid,
  result         text not null,
  attempted_at   timestamptz not null default now()
);
create index checkin_attempts_event_idx on public.checkin_attempts (event_id, attempted_at);

create table public.rate_limits (
  key           text not null,
  window_start  timestamptz not null,
  hits          integer not null default 0,
  primary key (key, window_start)
);

-- ---------------------------------------------------------------------------
-- updated_at
-- ---------------------------------------------------------------------------
create function public.touch_updated_at() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  return new;
end $$;

create trigger events_touch before update on public.events
  for each row execute function public.touch_updated_at();
create trigger ticket_types_touch before update on public.ticket_types
  for each row execute function public.touch_updated_at();
create trigger orders_touch before update on public.orders
  for each row execute function public.touch_updated_at();

-- ---------------------------------------------------------------------------
-- Row level security and grants
-- ---------------------------------------------------------------------------
alter table public.events           enable row level security;
alter table public.ticket_types     enable row level security;
alter table public.orders           enable row level security;
alter table public.tickets          enable row level security;
alter table public.payment_events   enable row level security;
alter table public.staff            enable row level security;
alter table public.checkin_attempts enable row level security;
alter table public.rate_limits      enable row level security;

-- Belt and braces: RLS already denies everything without a policy, but also take the
-- table privileges away so a future policy mistake can't expose these tables.
revoke all on public.events, public.ticket_types, public.orders, public.tickets,
  public.payment_events, public.staff, public.checkin_attempts, public.rate_limits
  from anon, authenticated;
revoke all on sequence public.payment_events_id_seq, public.checkin_attempts_id_seq
  from anon, authenticated;

-- Public catalogue: only the columns a visitor needs (no capacity or allocation).
grant select (id, name, kind, venue, address, doors_at, ends_at, min_age, status)
  on public.events to anon, authenticated;
grant select (id, event_id, name, perks, price_pence, currency, max_per_order,
              sales_start, sales_end, is_active, sort_order)
  on public.ticket_types to anon, authenticated;
grant select (user_id, role) on public.staff to authenticated;

create policy "Published events are public"
  on public.events for select to anon, authenticated
  using (status = 'published');

create policy "Active ticket types of published events are public"
  on public.ticket_types for select to anon, authenticated
  using (
    is_active and exists (
      select 1 from public.events e
      where e.id = ticket_types.event_id and e.status = 'published'
    )
  );

create policy "Staff can read their own role"
  on public.staff for select to authenticated
  using (user_id = (select auth.uid()));

-- Tables and functions created later in this schema are private until granted on purpose.
alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Availability helpers
-- A seat counts as taken when its order is paid or pending with a live hold. Orders in
-- review never received tickets and are refunded, so they don't hold seats.
-- ---------------------------------------------------------------------------
create function public.ticket_type_taken(p_ticket_type_id uuid) returns integer
language sql stable set search_path = '' as $$
  select coalesce(sum(o.quantity), 0)::integer
  from public.orders o
  where o.ticket_type_id = p_ticket_type_id
    and (o.status = 'paid'
         or (o.status = 'pending' and o.hold_expires_at > now()));
$$;

create function public.event_taken(p_event_id uuid) returns integer
language sql stable set search_path = '' as $$
  select coalesce(sum(o.quantity), 0)::integer
  from public.orders o
  where o.event_id = p_event_id
    and (o.status = 'paid'
         or (o.status = 'pending' and o.hold_expires_at > now()));
$$;

-- ---------------------------------------------------------------------------
-- Catalogue with live availability (used by the "events" Edge Function)
-- ---------------------------------------------------------------------------
create function public.public_event_listing() returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(ev order by ev->>'doors_at'), '[]'::jsonb)
  from (
    select jsonb_build_object(
      'id', e.id, 'name', e.name, 'kind', e.kind, 'venue', e.venue, 'address', e.address,
      'doors_at', e.doors_at, 'ends_at', e.ends_at, 'min_age', e.min_age,
      'ticket_types', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', t.id, 'name', t.name, 'perks', t.perks,
          'price_pence', t.price_pence, 'currency', t.currency,
          'max_per_order', t.max_per_order,
          'sale_state', case
            when t.sales_start is not null and now() < t.sales_start then 'not_started'
            when (t.sales_end is not null and now() >= t.sales_end) or now() >= e.ends_at then 'ended'
            when t.allocation - public.ticket_type_taken(t.id) <= 0
              or e.capacity - public.event_taken(e.id) <= 0 then 'sold_out'
            else 'on_sale'
          end
        ) order by t.sort_order, t.price_pence)
        from public.ticket_types t
        where t.event_id = e.id and t.is_active
      ), '[]'::jsonb)
    ) as ev
    from public.events e
    where e.status = 'published' and e.ends_at > now()
    order by e.doors_at
    limit 20
  ) s;
$$;

-- ---------------------------------------------------------------------------
-- Checkout: hold seats and create a pending order
-- Locks the event row so two buyers can never both take the last seats.
-- ---------------------------------------------------------------------------
create function public.reserve_tickets(
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
    event_id, ticket_type_id, quantity, unit_price_pence, amount_pence, currency,
    hold_expires_at, access_token_hash, client_key
  ) values (
    v_ev.id, v_tt.id, p_quantity, v_tt.price_pence, v_tt.price_pence * p_quantity, v_tt.currency,
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

-- Record which provider checkout belongs to a pending order.
create function public.attach_checkout(p_order_id uuid, p_provider text, p_checkout_id text)
returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  update public.orders
     set provider = p_provider, provider_checkout_id = p_checkout_id
   where id = p_order_id and status = 'pending' and provider is null;
  return found;
end $$;

-- Release the hold straight away when the provider checkout could not be created.
create function public.cancel_pending_order(p_order_id uuid) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  update public.orders set status = 'cancelled'
   where id = p_order_id and status = 'pending';
  return found;
end $$;

-- ---------------------------------------------------------------------------
-- Payment notifications (called only after the provider's signature is verified)
-- ---------------------------------------------------------------------------

-- Payment succeeded. Idempotent per provider event, checks the amount against the order,
-- and issues the tickets in the same transaction.
create function public.confirm_payment(
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
    -- Same payment reported again under a new event id is harmless. A different payment
    -- for an already-paid order means the buyer was charged twice and needs a refund.
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
    -- pending, or expired/cancelled but paid anyway: the buyer paid, so honour it
    -- unless that would oversell.
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

      v_outcome := case when v_late then 'fulfilled_late' else 'fulfilled' end;
    end if;
  end if;

  update public.payment_events
     set outcome = v_outcome, order_id = v_order.id
   where id = v_pe_id;

  return jsonb_build_object('outcome', v_outcome, 'order_id', v_order.id);
end $$;

-- Checkout abandoned or expired at the provider: free the seats.
create function public.release_order(
  p_provider text, p_provider_event_id text, p_event_type text, p_order_id uuid
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_pe_id   bigint;
  v_outcome text;
begin
  insert into public.payment_events (provider, provider_event_id, event_type, order_id)
  values (p_provider, p_provider_event_id, p_event_type,
          (select id from public.orders where id = p_order_id))
  on conflict (provider, provider_event_id) do nothing
  returning id into v_pe_id;

  if v_pe_id is null then
    return jsonb_build_object('outcome', 'duplicate');
  end if;

  update public.orders set status = 'expired'
   where id = p_order_id and status = 'pending' and provider = p_provider;
  v_outcome := case when found then 'released' else 'not_pending' end;

  update public.payment_events set outcome = v_outcome where id = v_pe_id;
  return jsonb_build_object('outcome', v_outcome);
end $$;

-- Full refund: cancel the order's unused tickets. Partial refunds are logged only.
create function public.refund_order(
  p_provider text, p_provider_event_id text, p_event_type text,
  p_payment_id text, p_full_refund boolean
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_pe_id   bigint;
  v_order   public.orders%rowtype;
  v_outcome text;
begin
  select * into v_order from public.orders
   where provider = p_provider and provider_payment_id = p_payment_id
   for update;

  insert into public.payment_events (provider, provider_event_id, event_type, order_id)
  values (p_provider, p_provider_event_id, p_event_type, v_order.id)
  on conflict (provider, provider_event_id) do nothing
  returning id into v_pe_id;

  if v_pe_id is null then
    return jsonb_build_object('outcome', 'duplicate');
  end if;

  if v_order.id is null then
    v_outcome := 'order_not_found';
  elsif not p_full_refund then
    v_outcome := 'partial_refund_logged';
  else
    update public.orders set status = 'refunded' where id = v_order.id;
    update public.tickets set status = 'cancelled'
     where order_id = v_order.id and status = 'active';
    v_outcome := 'refunded';
  end if;

  update public.payment_events set outcome = v_outcome where id = v_pe_id;
  return jsonb_build_object('outcome', v_outcome, 'order_id', v_order.id);
end $$;

-- ---------------------------------------------------------------------------
-- Buyer's ticket page: requires the order id AND the secret from the ticket link.
-- ---------------------------------------------------------------------------
create function public.get_order(p_order_id uuid, p_access_token_hash text) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', o.id,
    'status', o.status,
    'quantity', o.quantity,
    'amount_pence', o.amount_pence,
    'currency', o.currency,
    'email', o.email,
    'ticket_name', t.name,
    'event', jsonb_build_object('id', e.id, 'name', e.name, 'venue', e.venue,
                                'address', e.address, 'doors_at', e.doors_at,
                                'ends_at', e.ends_at, 'min_age', e.min_age),
    'tickets', case when o.status in ('paid', 'refunded') then coalesce((
      select jsonb_agg(jsonb_build_object('id', k.id, 'status', k.status,
                                          'checked_in_at', k.checked_in_at)
                       order by k.created_at, k.id)
      from public.tickets k where k.order_id = o.id), '[]'::jsonb)
      else '[]'::jsonb end
  )
  from public.orders o
  join public.events e on e.id = o.event_id
  join public.ticket_types t on t.id = o.ticket_type_id
  where o.id = p_order_id and o.access_token_hash = p_access_token_hash;
$$;

-- ---------------------------------------------------------------------------
-- Door check-in. One atomic UPDATE: if two scanners hit the same ticket at once,
-- exactly one gets "valid" and the other gets "already_used".
-- p_ticket_id is null when the scanned code failed signature verification.
-- ---------------------------------------------------------------------------
create function public.check_in_ticket(p_ticket_id uuid, p_event_id uuid, p_staff_user_id uuid)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_ticket  public.tickets%rowtype;
  v_result  text;
  v_type    text;
begin
  if not exists (select 1 from public.staff where user_id = p_staff_user_id) then
    raise exception 'not_staff' using errcode = '42501';
  end if;

  if p_ticket_id is null then
    v_result := 'invalid_code';
  else
    update public.tickets
       set status = 'used', checked_in_at = now(), checked_in_by = p_staff_user_id
     where id = p_ticket_id and event_id = p_event_id and status = 'active'
    returning * into v_ticket;

    if found then
      v_result := 'valid';
    else
      select * into v_ticket from public.tickets where id = p_ticket_id;
      v_result := case
        when not found then 'not_found'
        when v_ticket.event_id <> p_event_id then 'wrong_event'
        when v_ticket.status = 'used' then 'already_used'
        else 'cancelled'
      end;
    end if;
  end if;

  if v_ticket.ticket_type_id is not null then
    select name into v_type from public.ticket_types where id = v_ticket.ticket_type_id;
  end if;

  insert into public.checkin_attempts (ticket_id, event_id, staff_user_id, result)
  values (p_ticket_id, p_event_id, p_staff_user_id, v_result);

  return jsonb_build_object(
    'result', v_result,
    'ticket_type', case when v_result in ('valid', 'already_used') then v_type end,
    'checked_in_at', case when v_result in ('valid', 'already_used') then v_ticket.checked_in_at end
  );
end $$;

-- ---------------------------------------------------------------------------
-- Fixed-window rate limiting. Returns true when the call is allowed.
-- ---------------------------------------------------------------------------
create function public.hit_rate_limit(p_key text, p_window_seconds integer, p_max integer)
returns boolean
language plpgsql security definer set search_path = '' as $$
declare
  v_window timestamptz;
  v_hits   integer;
begin
  if p_window_seconds < 1 or p_max < 1 then
    raise exception 'invalid_rate_limit' using errcode = '22023';
  end if;

  v_window := to_timestamp(floor(extract(epoch from now()) / p_window_seconds) * p_window_seconds);

  insert into public.rate_limits (key, window_start, hits)
  values (p_key, v_window, 1)
  on conflict (key, window_start) do update set hits = public.rate_limits.hits + 1
  returning hits into v_hits;

  -- Occasional tidy-up of old windows.
  if random() < 0.02 then
    delete from public.rate_limits where window_start < now() - interval '1 day';
  end if;

  return v_hits <= p_max;
end $$;

-- ---------------------------------------------------------------------------
-- Function privileges: service_role only.
-- ---------------------------------------------------------------------------
revoke execute on function
  public.touch_updated_at(),
  public.ticket_type_taken(uuid),
  public.event_taken(uuid),
  public.public_event_listing(),
  public.reserve_tickets(uuid, integer, text, text, integer),
  public.attach_checkout(uuid, text, text),
  public.cancel_pending_order(uuid),
  public.confirm_payment(text, text, text, uuid, text, integer, text, text),
  public.release_order(text, text, text, uuid),
  public.refund_order(text, text, text, text, boolean),
  public.get_order(uuid, text),
  public.check_in_ticket(uuid, uuid, uuid),
  public.hit_rate_limit(text, integer, integer)
from public, anon, authenticated;

grant execute on function
  public.public_event_listing(),
  public.reserve_tickets(uuid, integer, text, text, integer),
  public.attach_checkout(uuid, text, text),
  public.cancel_pending_order(uuid),
  public.confirm_payment(text, text, text, uuid, text, integer, text, text),
  public.release_order(text, text, text, uuid),
  public.refund_order(text, text, text, text, boolean),
  public.get_order(uuid, text),
  public.check_in_ticket(uuid, uuid, uuid),
  public.hit_rate_limit(text, integer, integer)
to service_role;
