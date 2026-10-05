// Email provider registry. No provider has been chosen yet, so queued emails wait in the outbox
// and are sent once one is configured.
//
// To add one: write an adapter implementing EmailSender in this folder, register it below, then
// set the EMAIL_PROVIDER secret to its name.

import type { EmailSender } from "./types.ts";

const adapters: Record<string, () => EmailSender> = {
  // resend: () => createResendSender(),
};

/** The configured sender, or null while no email provider is set up. */
export function activeEmailSender(): EmailSender | null {
  const name = Deno.env.get("EMAIL_PROVIDER");
  if (!name) return null;
  const make = Object.hasOwn(adapters, name) ? adapters[name] : undefined;
  if (!make) throw new Error(`EMAIL_PROVIDER "${name}" has no adapter registered`);
  return make();
}
