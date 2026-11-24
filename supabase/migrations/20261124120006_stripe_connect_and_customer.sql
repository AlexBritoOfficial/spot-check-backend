-- Stripe-side identifiers and Connect onboarding state.
--
-- 20261124120002_payments.sql already models the money. What it never had was
-- the two ids Stripe needs to attach that money to a person:
--
--   profiles.stripe_customer_id         the paying side -- PaymentSheet cannot
--                                       show a saved card without a Customer
--   payout_accounts.charges_enabled /   the earning side -- how far through
--   details_submitted /                 Connect Express onboarding a filmer
--   onboarding_completed_at             actually is
--
-- Connect is Express: Stripe hosts the KYC and bank-details screens, which the
-- canvas never drew. Payouts.dc.html's "managed with Stripe" and "collected by
-- Stripe for payouts" are literally describing a Stripe-hosted flow, so the
-- app only ever opens an AccountLink and reads the result back from here.

-- ---------------------------------------------------------------------------
-- The paying side
-- ---------------------------------------------------------------------------

-- One Stripe Customer per profile, created lazily by the payment-intent
-- function on first checkout rather than at signup, so a user who never pays
-- never reaches Stripe at all.
alter table public.profiles
  add column stripe_customer_id text unique;

-- Deliberately NOT added to the column GRANT in 20261124120003_roles_rls.sql.
-- That migration revoked blanket UPDATE and re-granted an explicit column
-- list, so a column added afterwards is non-writable by `authenticated` by
-- default -- which is the behaviour we want and the reason the GRANT was
-- written as an allowlist. Section 1 of verify_roles_rls.sql now asserts it.
--
-- Why it matters here: pointing your own profile at someone else's
-- stripe_customer_id would let you pay with their saved cards.

-- ---------------------------------------------------------------------------
-- The earning side
-- ---------------------------------------------------------------------------

-- payouts_enabled already existed and means "Stripe will send money to the
-- bank". These three cover the rest of what Express onboarding reports, and
-- the distinction is not cosmetic:
--
--   details_submitted  the filmer finished the hosted form
--   charges_enabled    the platform may create charges destined for them
--   payouts_enabled    money can actually leave for their bank
--
-- A filmer can have details_submitted = true and both others false while
-- Stripe is still reviewing. FilmerTools must not advertise them as bookable
-- until charges_enabled, or a skater pays for a session that can never settle.
alter table public.payout_accounts
  add column charges_enabled        boolean not null default false,
  add column details_submitted      boolean not null default false,
  add column onboarding_completed_at timestamptz;

-- payout_accounts has a SELECT policy and no write policy at all, so none of
-- these are client-writable already. The webhook (service role) is the only
-- writer, exactly as with payments.

-- ---------------------------------------------------------------------------
-- Idempotency for the webhook
-- ---------------------------------------------------------------------------

-- Stripe retries a webhook until it gets a 2xx, and will happily deliver the
-- same event twice even after success. Without this, a redelivered
-- payment_intent.succeeded appends a second row to payment_events and the
-- TransactionDetail timeline grows a duplicate "Charged and held" line.
--
-- The event id is Stripe's (evt_...), so inserting it is the lock: a second
-- delivery hits the primary key and the handler returns early.
create table public.stripe_webhook_events (
  id           text primary key,
  type         text not null,
  received_at  timestamptz not null default now()
);

alter table public.stripe_webhook_events enable row level security;
-- No policy of any kind: service role bypasses RLS, and this is nobody's
-- business but the webhook's.

comment on table public.stripe_webhook_events is
  'Seen Stripe event ids, for webhook idempotency. Written only by the stripe-webhook function.';
