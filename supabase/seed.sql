-- First event, created as a DRAFT so it's invisible and can't be bought.
-- Before publishing, set the real capacity, prices (in pence: £15.00 = 1500), allocations and perks
-- in the Supabase Table Editor, then set events.status to 'published'.
-- Times are stored in UTC: 22:00 in London on 17 Oct 2026 (BST) is 21:00 UTC.
with ev as (
  insert into public.events (name, kind, venue, address, doors_at, ends_at, capacity, min_age, status)
  values ('Opening Night', 'club', 'Shoreditch 45', 'Shoreditch 45, London',
          '2026-10-17 21:00:00+00', '2026-10-18 03:00:00+00', 200, 18, 'draft')
  returning id
)
insert into public.ticket_types (event_id, name, perks, price_pence, allocation, max_per_order, sort_order)
select ev.id, t.name, t.perks, t.price_pence, t.allocation, t.max_per_order, t.sort_order
from ev, (values
  ('General Entry', array['Entry for one person', 'Access to main room'], 1500, 150, 10, 1),
  ('VIP Entry',     array['Fast-track entry', 'Reserved area'],          3000, 50,  6,  2)
) as t(name, perks, price_pence, allocation, max_per_order, sort_order);
