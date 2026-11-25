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
cat > /tmp/stripe.env <<'EOF'
STRIPE_SECRET_KEY=sk_test_...
STRIPE_WEBHOOK_SECRET=whsec_...
STRIPE_WEBHOOK_SECRET_CONNECT=whsec_...
EOF
supabase secrets set --remote=<ref> --env-file /tmp/stripe.env --yes
rm /tmp/stripe.env
```

Three things in that command are each a trap already hit:

- **`supabase login` first, not the CI token.** The deploy token's Edge Function Secrets scope is
  `None`, so it cannot write these. It is not an oversight.
- **`--remote=<ref>`, not `--project-ref`.** The latter still works but warns it is removed in v4,
  and `setup-cli` pulls `latest`.
- **`--yes`.** Hosted changes prompt for confirmation, and the CLI accepts that confirmation _only_
  from this flag or `SUPABASE_YES` exported in the shell — never from a `.env` file. Omitting it is
  what made the CI functions deploy fail with "Confirmation required ... Nothing was changed".

The heredoc keeps both values out of shell history, which passing them as arguments would not.

`CONNECT_RETURN_URL_BASE` is optional and defaults to the deployed web app. Only `pk_test_…` ever
reaches the iOS app, via the gitignored `Config/Secrets.xcconfig`.

**2. The event destinations — there are TWO, not one.**

Connect forces this. `accounts.create({ type: 'express' })` makes a **v1** connected account owned
directly by the platform, and the dashboard states the routing rule plainly: v1 platform-owned
account events go to **Connected accounts** destinations. So `account.updated` never arrives on a
"Your account" destination, and `payout_accounts` silently never updates — no error, just a filmer
who stays unbookable forever.

| Destination | Scope              | Events                                                            |
| ----------- | ------------------ | ----------------------------------------------------------------- |
| Platform    | Your account       | the 11 identity / payment_intent / charge / payment_method events |
| Connect     | Connected accounts | `account.updated` only                                            |

Both point at the same URL: `https://<ref>.supabase.co/functions/v1/stripe-webhook`

For both, set **Payload style: Snapshot** _before_ selecting events (switching it clears them). Thin
payloads carry no object data, and this handler reads `event.data.object` fields directly. Set **API
version** to `2026-11-18.endive` — the same version `_shared/stripe.ts` pins, so payload shapes
match the code.

The 11 for the platform destination:

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
payment_method.attached
payment_method.detached
```

and `account.updated` alone on the Connect destination.

**Each destination has its own signing secret**, so there are two:

```sh
STRIPE_WEBHOOK_SECRET=whsec_...          # platform destination
STRIPE_WEBHOOK_SECRET_CONNECT=whsec_...  # connected-accounts destination
```

`stripe-webhook` tries each in turn, because nothing in the request says which destination sent it.
The connect one is optional so a single-destination environment still works — but with Connect in
use and it unset, every `account.updated` is rejected as an invalid signature, which reads like a
signing bug rather than missing configuration.

A signing secret is only fully readable when its destination is created, and differs per destination
and per environment.

**Also dashboard-only, with no CLI equivalent:** enabling Identity, and enabling Connect with
Express plus the transfers capability.

## Local development

```sh
supabase functions serve                      # all five, with hot reload
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
