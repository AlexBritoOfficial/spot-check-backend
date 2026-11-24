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

// constructEventAsync needs a crypto provider that exists on the edge. Passed
// explicitly rather than relying on the default, because the failure mode is a
// webhook that rejects every signature as invalid.
export const cryptoProvider = Stripe.createSubtleCryptoProvider();

export const stripeWebhookSecret = () => requireEnv('STRIPE_WEBHOOK_SECRET');
