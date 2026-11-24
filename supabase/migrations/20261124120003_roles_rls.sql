-- RLS and column grants for capabilities, organizations and payments.
--
-- The governing rule, same as 20261118155807_rls.sql:41-43 for spots: RLS
-- restricts *rows*, not columns. Anything a user must not be able to set about
-- themselves is kept out of the column GRANT, because a row-level policy
-- saying "your own row" happily permits writing any column in it.

alter table public.identity_verifications  enable row level security;
alter table public.profile_capabilities    enable row level security;
alter table public.filmer_profiles         enable row level security;
alter table public.organizations           enable row level security;
alter table public.organization_members    enable row level security;
alter table public.organization_invites    enable row level security;
alter table public.payments                enable row level security;
alter table public.payment_events          enable row level security;
alter table public.payment_methods         enable row level security;
alter table public.payout_accounts         enable row level security;
alter table public.payouts                 enable row level security;
alter table public.payout_items            enable row level security;

-- ---------------------------------------------------------------------------
-- profiles: close the pre-existing escalation gap
-- ---------------------------------------------------------------------------

-- Until now `profiles` had an update policy and no column GRANT at all, so any
-- signed-in user could run `update profiles set filmer = true` on themselves.
-- The same hole would swallow identity_verified_at and identity_is_adult, which
-- gate payments. This is the fix, copied from the spots block.
--
-- Left out on purpose, and each for a reason:
--   filmer                 derived from profile_capabilities by trigger
--   identity_verified_at   written only by the Stripe Identity webhook
--   identity_is_adult      ditto -- self-declaring adulthood is the thing the
--                          18+ check exists to prevent
--   id, created_at, updated_at
revoke update on public.profiles from authenticated;
grant update (username, home_city, first_name, last_name, stance, discipline,
              avatar_url, age, years_skating) on public.profiles to authenticated;

-- ---------------------------------------------------------------------------
-- Identity
-- ---------------------------------------------------------------------------

-- Readable only by the person it is about: whether someone has verified their
-- identity is nobody else's business. There is no insert/update/delete policy,
-- so only the webhook (service role, which bypasses RLS) ever writes it.
create policy "users read their own identity verification"
  on public.identity_verifications for select to authenticated
  using (user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- Capabilities
-- ---------------------------------------------------------------------------

-- Readable by any signed-in user: the canvas shows a "Filmer" chip and a "Pro"
-- tag on other people's profiles, and ProProfile is the skater's view of a
-- filmer, so capability is public-facing information.
create policy "capabilities are readable by authenticated users"
  on public.profile_capabilities for select to authenticated using (true);

-- No insert/update/delete policy at all. Every grant path is a security definer
-- function: redeem_organization_invite for industry, submit_filmer_application
-- and filmer_go_live for filmer, and the service role for pro (invite-only,
-- granted by Spot Check -- the canvas has no "become a pro" flow).

-- ---------------------------------------------------------------------------
-- Filmer profiles
-- ---------------------------------------------------------------------------

-- Public: ProProfile renders a filmer's gear, styles and rates to the skater
-- deciding whether to book them.
create policy "filmer profiles are readable by authenticated users"
  on public.filmer_profiles for select to authenticated using (true);

create policy "filmers update their own filmer profile"
  on public.filmer_profiles for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- The split from the table definition, enforced. A filmer may edit what they
-- assert about themselves; they may not pass their own background check, clear
-- their own strikes, or un-pause themselves.
revoke update on public.filmer_profiles from authenticated;
grant update (gear, styles, reel_path, raw_clip_path, hourly_rate_cents,
              park_drop_in_cents, full_edit_quote_on_request, availability)
  on public.filmer_profiles to authenticated;

-- No insert policy: the row is created by submit_filmer_application, so a
-- filmer profile cannot exist without an application behind it.

-- ---------------------------------------------------------------------------
-- Organizations
-- ---------------------------------------------------------------------------

-- ProfileVisits shows skaters exactly which shop or brand viewed them by name,
-- so orgs and their membership are readable; "Member visits show as totals
-- only" is a query concern, not a row-visibility one.
create policy "organizations are readable by authenticated users"
  on public.organizations for select to authenticated using (true);

create policy "organization members are readable by authenticated users"
  on public.organization_members for select to authenticated using (true);

-- organization_invites gets NO policy of any kind. With RLS on and no policy,
-- every action is denied, so a code is unreadable even to the person it was
-- sent to -- redeem_organization_invite is the only thing that can see one.

-- ---------------------------------------------------------------------------
-- Payments
-- ---------------------------------------------------------------------------

create or replace function public.is_payment_party(p_payment_id uuid, p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.payments p
    where p.id = p_payment_id
      and (p.payer_id = p_user_id or p.payee_id = p_user_id)
  );
$$;

-- Both sides of a transaction can see it, nobody else can. Deliberately not
-- "readable by authenticated": what people pay each other is not directory
-- information the way a username is.
create policy "parties read their payments"
  on public.payments for select to authenticated
  using (payer_id = auth.uid() or payee_id = auth.uid());

create policy "parties read their payment events"
  on public.payment_events for select to authenticated
  using (public.is_payment_party(payment_id, auth.uid()));

create policy "users read their own payment methods"
  on public.payment_methods for select to authenticated
  using (user_id = auth.uid());

create policy "users read their own payout account"
  on public.payout_accounts for select to authenticated
  using (user_id = auth.uid());

create policy "payees read their own payouts"
  on public.payouts for select to authenticated
  using (payee_id = auth.uid());

create policy "payees read their own payout items"
  on public.payout_items for select to authenticated
  using (exists (
    select 1 from public.payouts po
    where po.id = payout_id and po.payee_id = auth.uid()
  ));

-- No insert/update/delete policy on any payments table. Money state is written
-- only by the Stripe webhook handler running as service role, via
-- record_payment_event. A client being able to set state = 'held' would mean a
-- booking could be confirmed without a charge ever succeeding.
