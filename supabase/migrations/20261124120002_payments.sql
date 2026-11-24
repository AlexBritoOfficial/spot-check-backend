-- Payments, payouts and the ledger behind the canvas's Transactions screens.
-- Stripe is the processor; every external id below is Stripe's.
--
-- Money is held by the platform between a filmer accepting and both sides
-- confirming (Checkout's "WHEN YOU'RE CHARGED"), which is Stripe Connect
-- separate charges and transfers: capture to the platform on accept, transfer
-- to the filmer on confirm. It is deliberately NOT a manual-capture
-- authorization hold -- those expire in about a week and cannot span an
-- arbitrary session date.

create type public.payment_kind as enum (
  'filming_session', 'pro_request', 'late_cancel_fee'
);

-- Covers every badge the canvas draws: HELD, PAID, REFUNDED, CREDIT, PAID OUT,
-- and the declined state.
create type public.payment_state as enum (
  'pending', 'processing', 'held', 'released',
  'refunded', 'credited', 'declined', 'cancelled'
);

-- Spot Check charges two different ways and the difference is who pays the
-- fee, so it is data rather than a constant:
--
--   filming     15% added ON TOP of the filmer's rate -> the skater bears it,
--               which is how Payouts promises "You keep 100% of your rate"
--   pro request 20% taken OUT of the price -> the pro bears it, which is what
--               ProReply's "Skater paid / Spot Check fee / You earn" shows
create type public.fee_bearer as enum ('payer', 'payee');

create sequence public.receipt_number_seq;

create table public.payments (
  id                       uuid primary key default gen_random_uuid(),
  kind                     public.payment_kind not null,
  state                    public.payment_state not null default 'pending',

  payer_id                 uuid not null references public.profiles(id) on delete restrict,
  payee_id                 uuid not null references public.profiles(id) on delete restrict,

  -- Amounts are integer minor units. Never floats: 15% of $45 is not
  -- representable in binary floating point and receipts must reconcile.
  subtotal_cents           integer not null check (subtotal_cents >= 0),
  fee_cents                integer not null check (fee_cents >= 0),
  -- Stored per payment, not read from a constant, so changing a rate never
  -- rewrites what someone was already charged.
  fee_basis_points         integer not null check (fee_basis_points between 0 and 10000),
  fee_bearer               public.fee_bearer not null,
  -- What the payer is charged.
  total_cents              integer not null check (total_cents >= 0),
  -- What the payee receives.
  payee_amount_cents       integer not null check (payee_amount_cents >= 0),
  currency                 text not null default 'usd',

  -- SC-000123 on TransactionDetail.
  receipt_number           text not null unique
                             default 'SC-' || lpad(nextval('public.receipt_number_seq')::text, 6, '0'),

  stripe_payment_intent_id text unique,
  stripe_charge_id         text unique,
  -- "Visa •••• 4242" -- a display string only. Never a card number.
  payment_method_label     text,

  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now(),

  constraint payments_parties_differ check (payer_id <> payee_id),

  -- Makes the two fee models impossible to record inconsistently.
  constraint payments_fee_model_consistent check (
    case fee_bearer
      when 'payer' then total_cents = subtotal_cents + fee_cents
                    and payee_amount_cents = subtotal_cents
      when 'payee' then total_cents = subtotal_cents
                    and payee_amount_cents = subtotal_cents - fee_cents
    end
  )
);

create index payments_payer_idx on public.payments (payer_id, created_at desc);
create index payments_payee_idx on public.payments (payee_id, created_at desc);

create trigger payments_touch_updated_at
  before update on public.payments
  for each row execute function public.touch_updated_at();

-- TransactionDetail's STATUS list is a history ("Requested Nov 19, 3:12 PM" /
-- "Charged and held ... Rider Okafor accepted"), not something derivable from
-- the current state, so it gets its own append-only table.
create table public.payment_events (
  id          uuid primary key default gen_random_uuid(),
  payment_id  uuid not null references public.payments(id) on delete cascade,
  state       public.payment_state not null,
  note        text,
  occurred_at timestamptz not null default now()
);

create index payment_events_payment_idx
  on public.payment_events (payment_id, occurred_at);

-- Saved methods. PaymentMethods.dc.html says it outright: "Spot Check never
-- stores your full card number." There is deliberately no column here that
-- could hold a PAN, CVC or expiry beyond what Stripe returns for display --
-- the card form in the app is replaced by Stripe's own input, so raw details
-- never reach this database.
create table public.payment_methods (
  id                       uuid primary key default gen_random_uuid(),
  user_id                  uuid not null references public.profiles(id) on delete cascade,
  stripe_payment_method_id text not null unique,
  -- 'visa', 'mastercard', or null for a wallet.
  brand                    text,
  last4                    text check (last4 is null or last4 ~ '^[0-9]{4}$'),
  exp_month                smallint check (exp_month is null or exp_month between 1 and 12),
  exp_year                 smallint check (exp_year is null or exp_year between 2000 and 2100),
  -- 'apple_pay' for the canvas's Apple Pay row.
  wallet                   text,
  is_default               boolean not null default false,
  created_at               timestamptz not null default now()
);

create unique index payment_methods_one_default_per_user
  on public.payment_methods (user_id)
  where is_default;

-- The earning side: a Stripe Connect account per filmer/pro. Payouts shows
-- "Bank account •••• 6789 -- Verified · managed with Stripe" and "Tax details
-- -- Complete · collected by Stripe for payouts", both of which are Stripe's
-- state reflected here, never ours to decide.
create table public.payout_accounts (
  user_id                     uuid primary key
                                references public.profiles(id) on delete cascade,
  stripe_connected_account_id text not null unique,
  bank_last4                  text check (bank_last4 is null or bank_last4 ~ '^[0-9]{4}$'),
  payouts_enabled             boolean not null default false,
  tax_details_complete        boolean not null default false,
  verified_at                 timestamptz,
  created_at                  timestamptz not null default now(),
  updated_at                  timestamptz not null default now()
);

create trigger payout_accounts_touch_updated_at
  before update on public.payout_accounts
  for each row execute function public.touch_updated_at();

create table public.payouts (
  id                 uuid primary key default gen_random_uuid(),
  payee_id           uuid not null references public.profiles(id) on delete restrict,
  amount_cents       integer not null check (amount_cents >= 0),
  currency           text not null default 'usd',
  state              public.payment_state not null default 'pending',
  -- "arrives in 1-2 business days"
  arrives_at         timestamptz,
  stripe_transfer_id text unique,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

create index payouts_payee_idx on public.payouts (payee_id, created_at desc);

create trigger payouts_touch_updated_at
  before update on public.payouts
  for each row execute function public.touch_updated_at();

-- A payout settles several payments at once -- the canvas groups one as
-- "2 filming sessions".
create table public.payout_items (
  payout_id  uuid not null references public.payouts(id) on delete cascade,
  payment_id uuid not null references public.payments(id) on delete restrict,
  primary key (payout_id, payment_id)
);

-- Records a state change and moves the payment in one step, so the ledger can
-- never drift from the timeline that renders it. Service role only: this is
-- called by the Stripe webhook handler, never by a client.
create or replace function public.record_payment_event(
  p_payment_id uuid,
  p_state      public.payment_state,
  p_note       text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.payments set state = p_state where id = p_payment_id;
  if not found then
    raise exception 'no such payment %', p_payment_id using errcode = '22023';
  end if;

  insert into public.payment_events (payment_id, state, note)
  values (p_payment_id, p_state, p_note);
end;
$$;

revoke all on function public.record_payment_event(uuid, public.payment_state, text)
  from public, anon, authenticated;
