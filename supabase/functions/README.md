# Edge Functions

Five functions, four of them called by the iOS app and one called by Stripe.

| Function             | Auth             | Does                                                                  |
| -------------------- | ---------------- | --------------------------------------------------------------------- |
| `identity-session`   | user JWT         | Starts/resumes a Stripe Identity session, returns its `client_secret` |
| `payment-intent`     | user JWT         | PaymentIntent + ephemeral key for an existing `payments` row          |
| `connect-onboarding` | user JWT         | Creates/refreshes a Connect **Express** account link                  |
| `release-payment`    | user JWT         | The payee delivers; transfers their share and releases                |
| `stripe-webhook`     | Stripe signature | The **only** writer of identity, payment and Connect state            |

`stripe-webhook` is the one function with `verify_jwt = false` (`supabase/config.toml`) — Stripe
does not send a Supabase JWT, so the `Stripe-Signature` header is the authentication.

## The escrow trail

The canvas draws four steps (`ClipVaultScreen.swift:55-60`). Where each is written:

| Step                | Written by                                                 |
| ------------------- | ---------------------------------------------------------- |
| Charged & held      | `stripe-webhook`, on `payment_intent.succeeded`            |
| Both confirmed      | `confirm_session_happened()` — either party, own side only |
| Raw clips delivered | `release-payment`, payee only                              |
| Filmer paid         | the same call — **delivering is what releases the money**  |

**Delivery is the release trigger.** The filmer sending the clip pays them (Alex, 2026-11-24), which
is what `ClipUploadScreen.swift:66` promised all along. The last two steps are therefore one atomic
operation, not two.

Two consequences worth knowing:

- **There is no auto-release timeout anywhere, and none is needed.** Nothing waits on the skater, so
  there is no way for them to leave a filmer unpaid by doing nothing. An earlier revision had the
  payer confirm receipt to release; `20261124120008` records why that was reversed.
- **"Both confirmed" does not gate delivery.** It is recorded as evidence for disputes. Gating on it
  would rebuild the same stall, with the skater withholding the session confirmation instead of the
  receipt one. That is a judgement call, flagged in `20261124120008`; reverse it by adding the check
  to `mark_payment_delivered`.

`payments.confirmed_at` survives from the previous revision as an informational receipt column.
Nothing writes it yet.

`transfer.reversed` is **not** handled by the webhook yet — a reversal would currently leave the
`payouts` row saying `released`.

## One-time setup per environment

Neither step is done by CI, on purpose.

**1. Function secrets.** The deploy token's Edge Function Secrets scope is `None`, so CI can ship
code but can never read or write a live key:

```sh
# --remote=<ref>, not --project-ref: `secrets set` is remote-only in CLI 3.x
# and defaults to the linked project. Needs `supabase login` first.
# Prefer --env-file so the values never reach shell history.
supabase secrets set --remote=<ref> --env-file ./stripe.env
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
