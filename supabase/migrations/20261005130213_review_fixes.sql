-- Review fixes (cubic):
-- * confirm_payment always takes the event lock and checks hold expiry against the wall clock,
--   so a payment confirmed right at the end of its hold can't race a new reservation for the
--   same seats.
-- * refund_order no longer records a refund it can't match yet, so an out-of-order refund is
--   retried by the provider instead of being lost.

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
  v_taken_tt integer;
  v_taken_ev integer;
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
    -- Always take the event lock, the same one reserve_tickets takes, so confirming a payment and
    -- selling the same seats to someone else can never interleave. Then judge lateness with the
    -- wall clock: now() is fixed when the transaction started, which may be before the hold ended.
    select * into v_ev from public.events where id = v_order.event_id for update;
    select * into v_tt from public.ticket_types where id = v_order.ticket_type_id;
    v_late := v_order.status <> 'pending' or v_order.hold_expires_at <= clock_timestamp();

    if v_late then
      -- Seats taken by everyone else right now (wall clock, excluding this order's own hold).
      select coalesce(sum(o.quantity) filter (where o.ticket_type_id = v_tt.id), 0),
             coalesce(sum(o.quantity), 0)
        into v_taken_tt, v_taken_ev
        from public.orders o
       where o.event_id = v_ev.id and o.id <> v_order.id
         and (o.status = 'paid' or (o.status = 'pending' and o.hold_expires_at > clock_timestamp()));
    end if;

    if v_late and (v_tt.allocation - v_taken_tt < v_order.quantity
                   or v_ev.capacity - v_taken_ev < v_order.quantity) then
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

create or replace function public.refund_order(
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

  -- Notifications can arrive out of order. A refund for a payment we haven't recorded yet is
  -- NOT marked as processed, so the provider's retry handles it once the payment has landed.
  if not found then
    return jsonb_build_object('outcome', 'order_not_found', 'retry', true);
  end if;

  insert into public.payment_events (provider, provider_event_id, event_type, order_id)
  values (p_provider, p_provider_event_id, p_event_type, v_order.id)
  on conflict (provider, provider_event_id) do nothing
  returning id into v_pe_id;

  if v_pe_id is null then
    return jsonb_build_object('outcome', 'duplicate');
  end if;

  if not p_full_refund then
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

revoke execute on function
  public.confirm_payment(text, text, text, uuid, text, integer, text, text),
  public.refund_order(text, text, text, text, boolean)
from public, anon, authenticated;

grant execute on function
  public.confirm_payment(text, text, text, uuid, text, integer, text, text),
  public.refund_order(text, text, text, text, boolean)
to service_role;
