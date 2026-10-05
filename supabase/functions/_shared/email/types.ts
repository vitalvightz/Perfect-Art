// The contract an email provider adapter must meet. Queueing, retries and content are
// provider-neutral; an adapter only has to deliver one message.

export interface OutgoingEmail {
  to: string;
  subject: string;
  html: string;
  text: string;
  /** Stable per queued email. Adapters should pass it to the provider so a retry after a crash
   * doesn't send the same email twice, where the provider supports that. */
  idempotencyKey: string;
}

export interface EmailSender {
  /** Short stable name, e.g. "resend". */
  readonly name: string;
  /** Throw PermanentEmailError for failures that retrying won't fix (e.g. an invalid address). */
  send(email: OutgoingEmail): Promise<{ messageId: string }>;
}

export class PermanentEmailError extends Error {}
