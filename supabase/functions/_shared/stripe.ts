// The Stripe client, shared by every function.
//
// Under Deno, `npm:stripe` resolves through the package's "deno" export
// condition to Stripe's *worker* build, which uses `fetch` and WebCrypto
// instead of Node's `http` and `crypto`. That is why no explicit
// `createFetchHttpClient()` is needed here -- getting this wrong shows up as
// "Cannot find module 'http'" at cold start, not as a test failure.
import Stripe from 'npm:stripe@23.2.0';

// Pinned, not left to default. The version determines the shape of every
// webhook payload this repo parses, so a silent bump is a silent change to
// `verified_outputs.dob` and friends. 2026-11-18.endive is what stripe-node
// 23.2.0 pins; the two are upgraded together, deliberately.
export const STRIPE_API_VERSION = '2026-11-18.endive';

function requireEnv(name: string): string {
  const value = Deno.env.get(name);
  if (!value) {
    // Loud and specific: a missing secret here is a deploy mistake, and the
    // alternative is a 500 from deep inside the Stripe SDK.
    throw new Error(`${name} is not set. Set it with: supabase secrets set ${name}=...`);
  }
  return value;
}

export const stripe = new Stripe(requireEnv('STRIPE_SECRET_KEY'), {
  apiVersion: STRIPE_API_VERSION,
});

/**
 * The restricted key that reads sensitive Identity results -- the document's
 * date of birth, which the 18+ check needs. The standard secret key is refused
 * these, so it is a key of its own, with only the "Identity Verification
 * Results" and "Recent Detailed Verification Results" read permissions.
 *
 * Read on use rather than at import, so the other functions sharing this
 * module still boot without it. A missing key fails the verified webhook with
 * a 500, which Stripe retries, rather than saving an unknown age.
 */
export const stripeIdentityResultsKey = (): string => requireEnv('STRIPE_IDENTITY_RESULTS_KEY');

// constructEventAsync needs a crypto provider that exists on the edge. Passed
// explicitly rather than relying on the default, because the failure mode is a
// webhook that rejects every signature as invalid.
export const cryptoProvider = Stripe.createSubtleCryptoProvider();

/**
 * Every signing secret a webhook delivery might have been signed with.
 *
 * There are two destinations, not one, and each has its own secret. Connect
 * forces this: our `accounts.create({ type: 'express' })` accounts are v1 and
 * owned directly by the platform, so their `account.updated` events are
 * delivered to a **Connected accounts** destination, while identity, payment
 * and payment-method events come from the **Your account** destination.
 * Putting all twelve events on one destination silently never updates
 * payout_accounts.
 *
 * The connect secret is optional so a single-destination environment still
 * works -- but if Connect onboarding is in use and this is unset, every
 * account.updated is rejected as an invalid signature, which looks like a
 * signing bug rather than missing configuration.
 */
export const stripeWebhookSecrets = (): string[] => {
  const secrets = [requireEnv('STRIPE_WEBHOOK_SECRET')];
  const connect = Deno.env.get('STRIPE_WEBHOOK_SECRET_CONNECT');
  if (connect) secrets.push(connect);
  return secrets;
};
