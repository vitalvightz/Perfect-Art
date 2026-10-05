-- Retries queued ticket emails every 2 minutes by calling the send-emails Edge Function.
-- The shared secret is generated here and kept in Vault, so it never appears in code.
-- Copy it into the EMAIL_CRON_SECRET Edge Function secret:
--   select decrypted_secret from vault.decrypted_secrets where name = 'email_cron_secret';
-- Until that's set (and an email provider is configured) the calls are harmless no-ops.
create extension if not exists pg_net;
create extension if not exists pg_cron;

select vault.create_secret(
  encode(extensions.gen_random_bytes(32), 'hex'),
  'email_cron_secret',
  'Shared secret for the send-emails Edge Function. Copy into the EMAIL_CRON_SECRET Edge Function secret.'
);

select cron.schedule(
  'send-ticket-emails',
  '*/2 * * * *',
  $$
  select net.http_post(
    url := 'https://bsxlhszipbrlisiyuwxh.supabase.co/functions/v1/send-emails',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'email_cron_secret')
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 15000
  );
  $$
);
