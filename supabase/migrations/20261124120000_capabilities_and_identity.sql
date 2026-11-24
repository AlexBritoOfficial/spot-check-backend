-- Account capabilities and shared identity verification.
--
-- The app has one kind of account: a skater. Filmer, industry and pro are
-- *capabilities* layered onto that profile, each with its own verification
-- state, rather than mutually exclusive account types. The canvas is what
-- forces this -- its screens interleave both sides of a transaction
-- (FilmerOnboarding/ProProfileScreen is the skater's view of a filmer,
-- FilmerTools/RatingScreen is instantiated from the skater's side), which
-- reads as a mode a person is in, not an account they signed up for.
--
-- `pro_skater`, not `pro`: `difficulty` already has a 'pro' label meaning
-- spot difficulty, and the two are unrelated.

create type public.capability as enum ('filmer', 'industry', 'pro_skater');

-- Absence of a profile_capabilities row means "doesn't have it", so there is
-- no 'none'. 'applied' is self-serve (filmer); 'active' is granted.
create type public.capability_status as enum (
  'applied', 'in_review', 'active', 'paused', 'revoked'
);

create type public.review_status as enum (
  'pending', 'in_review', 'passed', 'failed'
);

-- Mirrors Stripe Identity's VerificationSession.status values exactly, so the
-- webhook never has to translate.
create type public.identity_status as enum (
  'requires_input', 'processing', 'verified', 'canceled'
);

-- ---------------------------------------------------------------------------
-- Shared identity verification (Stripe Identity)
-- ---------------------------------------------------------------------------

-- Verification is triggered by *money movement*, not by holding a capability.
-- Trust/IDVerifyScreen.swift:19 states the rule: "Everyone who books, pays or
-- gets paid verifies once." So a plain skater booking a filmer verifies, while
-- an industry account never does -- no money flows through Spot Check for them
-- (Opportunities/SendOpportunityScreen.swift:95).
--
-- One row per person, keyed by user: the canvas says "verifies once". A
-- canceled or failed attempt is retried by reusing the row with a new session.
create table public.identity_verifications (
  user_id                        uuid primary key
                                   references public.profiles(id) on delete cascade,
  stripe_verification_session_id text not null unique,
  status                         public.identity_status not null default 'requires_input',
  -- Stripe's last_error.code (e.g. 'document_expired'), so IDVerify can tell
  -- the user why rather than just failing.
  last_error_code                text,
  -- Computed from Stripe's verified_outputs.dob at webhook time and then
  -- discarded. We deliberately never store the date of birth: IDVerifyScreen
  -- promises "Spot Check only keeps your verified status and age", and
  -- adulthood is the only fact any rule actually needs.
  verified_is_adult              boolean,
  verified_at                    timestamptz,
  created_at                     timestamptz not null default now(),
  updated_at                     timestamptz not null default now()
);

create trigger identity_verifications_touch_updated_at
  before update on public.identity_verifications
  for each row execute function public.touch_updated_at();

-- Denormalized onto profiles so the common "can this person pay?" check is a
-- column read on a row the app already fetches, rather than a join on every
-- profile load. Maintained only by the trigger below -- never client-writable
-- (see the column GRANT in the RLS migration).
alter table public.profiles
  add column identity_verified_at timestamptz,
  add column identity_is_adult    boolean;

-- `age` stays exactly as it was: self-reported, user-editable, and allowed to
-- be as low as 13. It is NOT a gate and must never be used as one -- that is
-- the whole reason identity_is_adult exists separately.

create or replace function public.mirror_identity_verification()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status = 'verified' then
    update public.profiles p
       set identity_verified_at = coalesce(new.verified_at, now()),
           identity_is_adult    = new.verified_is_adult
     where p.id = new.user_id;
  end if;
  return new;
end;
$$;

create trigger identity_verifications_mirror
  after insert or update on public.identity_verifications
  for each row execute function public.mirror_identity_verification();

-- ---------------------------------------------------------------------------
-- Capabilities
-- ---------------------------------------------------------------------------

create table public.profile_capabilities (
  user_id    uuid not null references public.profiles(id) on delete cascade,
  capability public.capability not null,
  status     public.capability_status not null default 'applied',
  granted_at timestamptz,
  revoked_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, capability)
);

create index profile_capabilities_active_idx
  on public.profile_capabilities (capability)
  where status = 'active';

create trigger profile_capabilities_touch_updated_at
  before update on public.profile_capabilities
  for each row execute function public.touch_updated_at();

-- profiles.filmer predates this and is read by SkaterProfileScreen's "Filmer"
-- chip and by the web app's generated types. Rather than drop it and break
-- both, it becomes a derived mirror of the filmer capability: still readable,
-- no longer writable by anyone (not even this trigger's caller).
create or replace function public.mirror_filmer_capability()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  target uuid := coalesce(new.user_id, old.user_id);
begin
  update public.profiles p
     set filmer = exists (
           select 1 from public.profile_capabilities pc
            where pc.user_id = target
              and pc.capability = 'filmer'
              and pc.status = 'active'
         )
   where p.id = target;
  return null;
end;
$$;

create trigger profile_capabilities_mirror_filmer
  after insert or update or delete on public.profile_capabilities
  for each row execute function public.mirror_filmer_capability();

-- Readable helper for RLS and RPCs elsewhere.
create or replace function public.has_capability(p_user_id uuid, p_capability public.capability)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.profile_capabilities pc
    where pc.user_id = p_user_id
      and pc.capability = p_capability
      and pc.status = 'active'
  );
$$;

-- ---------------------------------------------------------------------------
-- Filmer profile
-- ---------------------------------------------------------------------------

-- Filmer status cannot be a boolean. FilmerOnboarding/ProApplyScreen draws a
-- four-step gate and Verification tracks four sub-states, with
-- FilmerTools/StrikePausedScreen as a terminal pause. The split below matters:
-- the first block is what a filmer asserts about themselves, the second is
-- what Spot Check decides about them, and only the first is grantable to the
-- client.
create table public.filmer_profiles (
  user_id                    uuid primary key
                               references public.profiles(id) on delete cascade,

  -- self-asserted
  gear                       text[] not null default '{}',
  styles                     text[] not null default '{}',
  reel_path                  text,
  -- FilmerQualifyScreen marks the raw follow-line clip "Required": it is the
  -- one that proves a steady frame at speed.
  raw_clip_path              text,
  hourly_rate_cents          integer check (hourly_rate_cents is null or hourly_rate_cents >= 0),
  park_drop_in_cents         integer check (park_drop_in_cents is null or park_drop_in_cents >= 0),
  full_edit_quote_on_request boolean not null default true,
  availability               jsonb not null default '{}'::jsonb,

  -- decided by Spot Check
  consent_signed_at          timestamptz,
  gear_review_status         public.review_status not null default 'pending',
  background_check_status    public.review_status not null default 'pending',
  went_live_at               timestamptz,
  strike_count               integer not null default 0 check (strike_count between 0 and 3),
  paused_at                  timestamptz,

  created_at                 timestamptz not null default now(),
  updated_at                 timestamptz not null default now()
);

create trigger filmer_profiles_touch_updated_at
  before update on public.filmer_profiles
  for each row execute function public.touch_updated_at();
