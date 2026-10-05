// Payment provider registry. No provider has been chosen yet, so ticket sales stay closed.
//
// To add one: write an adapter implementing PaymentProvider in this folder (for example
// stripe.ts), register it below, then set the PAYMENT_PROVIDER secret to its name.

import type { PaymentProvider } from "./types.ts";

const adapters: Record<string, () => PaymentProvider> = {
  // stripe: () => createStripeProvider(),
};

export function providerByName(name: string): PaymentProvider | null {
  const make = Object.hasOwn(adapters, name) ? adapters[name] : undefined;
  return make ? make() : null;
}

/** The provider used for new checkouts, or null while sales are closed. */
export function activeProvider(): PaymentProvider | null {
  const name = Deno.env.get("PAYMENT_PROVIDER");
  if (!name) return null;
  const provider = providerByName(name);
  if (!provider) throw new Error(`PAYMENT_PROVIDER "${name}" has no adapter registered`);
  return provider;
}
