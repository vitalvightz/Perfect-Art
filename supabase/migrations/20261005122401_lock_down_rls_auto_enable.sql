-- rls_auto_enable() is Supabase's built-in event trigger that switches RLS on for new tables.
-- It can't be called through the API (it returns event_trigger), but it is SECURITY DEFINER and
-- executable by the API roles, which the security advisor flags. Event triggers don't need
-- EXECUTE to fire, so revoking it changes nothing except clearing the warning.
revoke execute on function public.rls_auto_enable() from public, anon, authenticated;
