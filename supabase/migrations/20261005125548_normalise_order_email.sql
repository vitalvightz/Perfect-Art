-- Store order emails trimmed and lower-case on every write, whatever the caller sends, so
-- "Find my tickets" lookups always match. (confirm_payment lower-cased but didn't trim.)
create function public.normalise_order_email() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.email := nullif(lower(trim(new.email)), '');
  return new;
end $$;

revoke execute on function public.normalise_order_email() from public, anon, authenticated;

create trigger orders_normalise_email before insert or update of email on public.orders
  for each row execute function public.normalise_order_email();

update public.orders set email = email where email is distinct from nullif(lower(trim(email)), '');
