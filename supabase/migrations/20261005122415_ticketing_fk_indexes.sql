-- Cover the remaining foreign keys flagged by the performance advisor.
create index payment_events_order_id_idx on public.payment_events (order_id);
create index tickets_ticket_type_id_idx on public.tickets (ticket_type_id);
create index tickets_checked_in_by_idx on public.tickets (checked_in_by);
