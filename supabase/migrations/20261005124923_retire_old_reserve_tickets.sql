-- The previous reserve_tickets signature was replaced by the one that takes the order id
-- (see the ticket_emails migration). Take away the last role that could call it.
-- It can be dropped from the SQL editor with:
--   drop function public.reserve_tickets(uuid, integer, text, text, integer);
revoke execute on function public.reserve_tickets(uuid, integer, text, text, integer) from service_role;
