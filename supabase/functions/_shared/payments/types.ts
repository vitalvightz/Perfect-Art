// The contract a payment provider adapter must meet. Everything else (holds, idempotency,
// amount checks, ticket issuing, refunds) is provider-neutral and lives in the database.

export interface CheckoutRequest {
  orderId: string;
  /** Total to charge, in minor units (pence). Always taken from the database, never the client. */
  amountPence: number;
  /** Lower-case ISO currency code, e.g. "gbp". */
  currency: string;
  quantity: number;
  unitPricePence: number;
  /** What the buyer sees on the payment page, e.g. "Opening Night: VIP Entry". */
  description: string;
  /** Where the provider sends the buyer after paying. Carries only the order id: the ticket link
   * secret must never be sent to the provider. */
  successUrl: string;
  /** Where the provider sends the buyer if they back out. */
  cancelUrl: string;
  /** The provider's checkout must stop accepting payment by this time (before our hold ends). */
  expiresAt: Date;
}

export interface CheckoutSession {
  /** The provider's id for this checkout, stored on the order. */
  checkoutId: string;
  /** Hosted payment page to send the buyer to. */
  redirectUrl: string;
}

/** A provider notification, after its signature has been verified. */
export type PaymentNotice =
  | {
    kind: "paid";
    /** Unique id of this notification at the provider. Used for idempotency. */
    eventId: string;
    eventType: string;
    orderId: string;
    paymentId: string;
    amountPence: number;
    currency: string;
    email: string | null;
  }
  | { kind: "expired"; eventId: string; eventType: string; orderId: string }
  | { kind: "refunded"; eventId: string; eventType: string; paymentId: string; fullRefund: boolean }
  | { kind: "ignored"; eventType: string };

export interface PaymentProvider {
  /** Short stable name, stored on orders, e.g. "stripe". */
  readonly name: string;
  createCheckout(req: CheckoutRequest): Promise<CheckoutSession>;
  /**
   * Verify the notification's signature and translate it. Must throw if the signature is missing
   * or wrong. Must only report "paid" when the money has actually been captured.
   */
  parseWebhook(req: Request): Promise<PaymentNotice>;
}
