# Edge Functions

Five functions, four of them called by the iOS app and one called by Stripe.

| Function             | Auth             | Does                                                                  |
| -------------------- | ---------------- | --------------------------------------------------------------------- |
| `identity-session`   | user JWT         | Starts/resumes a Stripe Identity session, returns its `client_secret` |
| `payment-intent`     | user JWT         | PaymentIntent + ephemeral key for an existing `payments` row          |
| `connect-onboarding` | user JWT         | Creates/refreshes a Connect **Express** account link                  |
| `release-payment`    | user JWT         | The payer confirms receipt; transfers the payee's share               |
| `stripe-webhook`     | Stripe signature | The **only** writer of identity, payment and Connect state            |

`stripe-webhook` is the one function with `verify_jwt = false` (`supabase/config.toml`) — Stripe
does not send a Supabase JWT, so the `Stripe-Signature` header is the authentication.

## The escrow trail

The canvas draws four steps (`ClipVaultScreen.swift:55-60`), and this is where each one gets
written:

| Step                | Written by                                                                        |
| ------------------- | --------------------------------------------------------------------------------- |
| Charged & held      | `stripe-webhook`, on `payment_intent.succeeded`                                   |
| Both confirmed      | **not modelled yet** — a separate pair of confirmations that the session happened |
| Raw clips delivered | `mark_payment_delivered()`, callable only by the payee                            |
| Filmer paid         | `release-payment`, callable only by the payer                                     |

The payer confirming receipt is what moves the money. A failed transfer leaves the confirmation
recorded and the payment still `held`, so it is retryable without asking the skater to confirm
twice.

`transfer.reversed` is **not** handled by the webhook yet — a reversal would currently leave the
`payouts` row saying `released`.

## One-time setup per environment

Neither step is done by CI, on purpose.

**1. Function secrets.** The deploy token's Edge Function Secrets scope is `None`, so CI can ship
code but can never read or write a live key:

```sh
supabase secrets set \
  STRIPE_SECRET_KEY=sk_test_... \
  STRIPE_WEBHOOK_SECRET=whsec_... \
  --project-ref <ref>
```

`CONNECT_RETURN_URL_BASE` is optional and defaults to the deployed web app. Only `pk_test_…` ever
reaches the iOS app, via the gitignored `Config/Secrets.xcconfig`.

**2. The webhook endpoint.** In the Stripe dashboard, point an endpoint at
`https://<ref>.functions.supabase.co/stripe-webhook` and subscribe it to exactly these events — the
handler ignores anything else, but an endpoint that sends nothing is the usual reason state never
updates:

```
identity.verification_session.verified
identity.verification_session.requires_input
identity.verification_session.processing
identity.verification_session.canceled
payment_intent.processing
payment_intent.succeeded
payment_intent.payment_failed
payment_intent.canceled
charge.refunded
account.updated
payment_method.attached
payment_method.detached
```

The signing secret shown when the endpoint is created is `STRIPE_WEBHOOK_SECRET` above. It differs
per endpoint, so Test/QA, Staging and Production each have their own.

## Local development

```sh
supabase functions serve                      # all four, with hot reload
stripe listen --forward-to localhost:54321/functions/v1/stripe-webhook
```

`stripe listen` prints its own `whsec_…`; put it in `supabase/.env.local` rather than exporting it,
so it never reaches a shell history.

## Type-checking

There is no Deno on the dev machine. From the repo root:

```sh
docker run --rm -v "$PWD/supabase/functions":/fn -w /fn \
  --entrypoint deno denoland/deno:latest check */index.ts
```

## Versions

`stripe@23.2.0`, API version `2026-11-18.endive` — pinned together in `_shared/stripe.ts`, because
the API version decides the shape of every webhook payload parsed here. Under Deno, `npm:stripe`
resolves through the package's `deno` export condition to Stripe's worker build (fetch + WebCrypto),
which is why no explicit HTTP client is configured.

Use `constructEventAsync`, never `constructEvent` — as of 23.x the sync version throws an error
telling you so.
