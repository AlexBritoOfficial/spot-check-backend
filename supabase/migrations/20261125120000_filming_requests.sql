-- Filming requests: the booking a filming payment is for.
--
-- Until now a `payments` row had nothing behind it -- DiscoverScreen's
-- accept/pass state was local view state and no table held the session's
-- date, place, conditions or price. This adds that table, the four actions on
-- it, and the late-cancellation rules Alex set on 2026-11-24:
--
--   * Late = cancelled LESS than 5 hours before the session starts.
--     Exactly 5 hours before is still on time.
--   * It applies to both sides:
--       filmer cancels late -> a strike; the third pauses their profile
--                              (StrikePausedScreen). The skater is refunded.
--       skater cancels late -> owes 15% of the rate, paid to Spot Check.
--
-- This deliberately REPLACES the canvas's skater policy ("Cancel under 24
-- hours: you pay 50%", FilmBookingScreen / CheckoutScreen). Alex chose the
-- 5-hour rule for both sides; the app copy is what changes.
--
-- Money is not moved here. Charging when a filmer accepts, refunding, and
-- charging the late fee are Stripe calls and belong to the Edge Functions;
-- this records what is owed so they have something to act on.

-- ---------------------------------------------------------------------------
-- Types -- the options FilmBookingScreen draws
-- ---------------------------------------------------------------------------

create type public.filming_package as enum (
  'hourly_street',  -- "Hourly Street Session": billed by the hour
  'park_drop_in',   -- "Park Drop-In": a flat 30-60 min block
  'full_edit'       -- "Full Edit Package": quoted on request
);

create type public.session_lighting as enum ('daylight', 'golden_hour', 'night');

create type public.security_risk as enum ('low', 'sometimes', 'kicks_out_fast');

-- No 'completed' yet: nothing would set it. Delivery is tracked on the
-- payment (delivered_at), and a status can be added when something needs it.
create type public.filming_request_status as enum ('requested', 'accepted', 'cancelled');

create type public.request_party as enum ('skater', 'filmer');

-- ---------------------------------------------------------------------------
-- filming_requests
-- ---------------------------------------------------------------------------

create table public.filming_requests (
  id                    uuid primary key default gen_random_uuid(),
  skater_id             uuid not null references public.profiles(id) on delete restrict,
  -- Set when the skater "chose you from your profile" (DiscoverScreen);
  -- null means any filmer nearby can take it.
  requested_filmer_id   uuid references public.profiles(id) on delete restrict,
  -- Whoever accepted. Null until then.
  filmer_id             uuid references public.profiles(id) on delete restrict,

  package               public.filming_package not null,

  -- Where. A skatepark is a spot; a street pin need not be one, so the point
  -- is always stored and the spot is optional. Same lat/lng + generated
  -- geography pattern as `spots`, so "near you" can use the same index type.
  spot_id               uuid references public.spots(id) on delete set null,
  lat                   double precision not null check (lat between -90 and 90),
  lng                   double precision not null check (lng between -180 and 180),
  lat_lng               extensions.geography(Point, 4326)
                          generated always as (
                            extensions.st_setsrid(extensions.st_makepoint(lng, lat), 4326)::extensions.geography
                          ) stored,
  -- "Pin near Copley Square", as Checkout shows it.
  location_label        text,

  starts_at             timestamptz not null,
  ends_at               timestamptz not null,
  lighting              public.session_lighting not null,
  security_risk         public.security_risk not null,
  notes                 text,

  -- The filmer's price, copied when they accept, so a filmer changing their
  -- rates later never reprices a session someone already booked. Excludes
  -- Spot Check's 15%, which is added on top at payment time.
  rate_cents            integer check (rate_cents is null or rate_cents >= 0),

  status                public.filming_request_status not null default 'requested',
  accepted_at           timestamptz,
  cancelled_at          timestamptz,
  cancelled_by          public.request_party,
  cancellation_was_late boolean,

  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),

  constraint filming_requests_ends_after_start check (ends_at > starts_at),
  constraint filming_requests_not_self_requested
    check (requested_filmer_id is null or requested_filmer_id <> skater_id),
  constraint filming_requests_not_self_filmed
    check (filmer_id is null or filmer_id <> skater_id),
  -- A named request can only be accepted by the person it names.
  constraint filming_requests_named_filmer_accepts
    check (requested_filmer_id is null or filmer_id is null or filmer_id = requested_filmer_id),

  -- Each status carries exactly the fields that describe it, so a row can
  -- never claim to be accepted without saying by whom and for how much.
  constraint filming_requests_status_fields check (
    case status
      when 'requested' then filmer_id is null and accepted_at is null and rate_cents is null
                        and cancelled_at is null and cancelled_by is null
                        and cancellation_was_late is null
      when 'accepted'  then filmer_id is not null and accepted_at is not null
                        and rate_cents is not null
                        and cancelled_at is null and cancelled_by is null
                        and cancellation_was_late is null
      when 'cancelled' then cancelled_at is not null and cancelled_by is not null
                        and cancellation_was_late is not null
                        -- A filmer can only cancel what they accepted.
                        and (cancelled_by = 'skater' or filmer_id is not null)
    end
  )
);

create index filming_requests_skater_idx on public.filming_requests (skater_id, starts_at desc);
create index filming_requests_filmer_idx on public.filming_requests (filmer_id, starts_at desc)
  where filmer_id is not null;
-- Discover's query: open requests that haven't started.
create index filming_requests_open_idx on public.filming_requests (starts_at)
  where status = 'requested';
create index filming_requests_lat_lng_gix on public.filming_requests using gist (lat_lng);

create trigger filming_requests_touch_updated_at
  before update on public.filming_requests
  for each row execute function public.touch_updated_at();

-- A pass is per filmer: it takes the request out of *their* Discover and
-- changes nothing for the skater or for any other filmer.
create table public.filming_request_passes (
  request_id uuid not null references public.filming_requests(id) on delete cascade,
  filmer_id  uuid not null references public.profiles(id) on delete cascade,
  passed_at  timestamptz not null default now(),
  primary key (request_id, filmer_id)
);

-- ---------------------------------------------------------------------------
-- payments: link to the request, and let Spot Check be a late fee's payee
-- ---------------------------------------------------------------------------

alter table public.payments
  add column filming_request_id uuid references public.filming_requests(id) on delete restrict;

create index payments_filming_request_idx on public.payments (filming_request_id)
  where filming_request_id is not null;

-- One session charge and at most one late fee per request.
create unique index payments_one_session_charge_per_request
  on public.payments (filming_request_id)
  where kind = 'filming_session' and filming_request_id is not null;
create unique index payments_one_late_fee_per_request
  on public.payments (filming_request_id)
  where kind = 'late_cancel_fee' and filming_request_id is not null;

-- "Spot Check receives it" -- but payee_id referenced a person, and there is
-- no person to be Spot Check. Rather than invent a platform profile (which
-- would need an auth user, and would show up wherever profiles are listed),
-- a late fee has NO payee. The amount is recorded entirely as fee:
-- subtotal 0, fee = total, payee_amount 0 -- which the existing
-- payments_fee_model_consistent check already accepts for fee_bearer 'payer'.
--
-- Safe for the Edge Functions: release-payment compares payee_id to the
-- caller, so a null payee can never be released to anyone.
alter table public.payments alter column payee_id drop not null;

alter table public.payments add constraint payments_payee_matches_kind check (
  case kind
    when 'late_cancel_fee' then payee_id is null
    else payee_id is not null
  end
);

comment on column public.payments.payee_id is
  'Who is paid. Null exactly when kind = late_cancel_fee: that money goes to Spot Check.';

-- ---------------------------------------------------------------------------
-- The 5-hour rule
-- ---------------------------------------------------------------------------

-- Its own function so the boundary is stated, tested and reused in one place.
-- Strictly greater-than: cancelling exactly 5 hours before is on time.
create or replace function public.is_late_cancellation(
  p_starts_at    timestamptz,
  p_cancelled_at timestamptz
)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_cancelled_at > p_starts_at - interval '5 hours';
$$;

-- Spot Check's cut of a late skater cancellation, as basis points of the rate.
-- Same 15% as the filming fee, but a separate statement of it: if one changes,
-- the other should not silently follow.
create or replace function public.late_cancel_fee_basis_points()
returns integer
language sql
immutable
set search_path = ''
as $$ select 1500 $$;

-- ---------------------------------------------------------------------------
-- Actions. RLS grants no writes on either table: every change goes through one
-- of these, which check who is calling. Same pattern as payments.
-- ---------------------------------------------------------------------------

-- An active, unpaused filmer. has_capability already requires status
-- 'active'; paused_at is checked too because the two are set together and a
-- row with only one of them set should still fail closed.
create or replace function public.is_bookable_filmer(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.has_capability(p_user_id, 'filmer')
     and exists (
       select 1 from public.filmer_profiles fp
        where fp.user_id = p_user_id and fp.paused_at is null
     );
$$;

create or replace function public.create_filming_request(
  p_package             public.filming_package,
  p_starts_at           timestamptz,
  p_ends_at             timestamptz,
  p_lat                 double precision,
  p_lng                 double precision,
  p_lighting            public.session_lighting,
  p_security_risk       public.security_risk,
  p_spot_id             uuid default null,
  p_location_label      text default null,
  p_notes               text default null,
  p_requested_filmer_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_id   uuid;
begin
  if v_user is null then
    raise exception 'sign in to request a filmer' using errcode = '42501';
  end if;

  if p_starts_at <= now() then
    raise exception 'a session must start in the future' using errcode = '22023';
  end if;

  if p_ends_at <= p_starts_at then
    raise exception 'a session must end after it starts' using errcode = '22023';
  end if;

  if p_requested_filmer_id is not null
     and (p_requested_filmer_id = v_user
          or not public.is_bookable_filmer(p_requested_filmer_id)) then
    raise exception 'that filmer is not taking requests' using errcode = '22023';
  end if;

  insert into public.filming_requests (
    skater_id, requested_filmer_id, package, spot_id, lat, lng, location_label,
    starts_at, ends_at, lighting, security_risk, notes
  ) values (
    v_user, p_requested_filmer_id, p_package, p_spot_id, p_lat, p_lng, p_location_label,
    p_starts_at, p_ends_at, p_lighting, p_security_risk, p_notes
  )
  returning id into v_id;

  return v_id;
end;
$$;

-- p_quote_cents is required for a full edit ("quote on request") and ignored
-- otherwise: hourly and drop-in prices come from the filmer's own rates.
create or replace function public.accept_filming_request(
  p_request_id  uuid,
  p_quote_cents integer default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user    uuid := auth.uid();
  v_request public.filming_requests%rowtype;
  v_profile public.filmer_profiles%rowtype;
  v_rate    integer;
begin
  if v_user is null or not public.is_bookable_filmer(v_user) then
    raise exception 'only an active filmer can accept requests' using errcode = '42501';
  end if;

  -- Locked so two filmers accepting at once cannot both win.
  select * into v_request
    from public.filming_requests
   where id = p_request_id
     for update;

  if not found then
    raise exception 'no such request %', p_request_id using errcode = '22023';
  end if;

  if v_request.skater_id = v_user then
    raise exception 'you cannot film your own request' using errcode = '42501';
  end if;

  if v_request.requested_filmer_id is not null and v_request.requested_filmer_id <> v_user then
    raise exception 'this request was sent to another filmer' using errcode = '42501';
  end if;

  if v_request.status <> 'requested' then
    raise exception 'this request is no longer open' using errcode = '22023';
  end if;

  if v_request.starts_at <= now() then
    raise exception 'this session has already started' using errcode = '22023';
  end if;

  select * into v_profile from public.filmer_profiles where user_id = v_user;

  v_rate := case v_request.package
    -- Billed by the minute at the hourly rate, rounded to the cent: 5-7 PM at
    -- $60/hr is $120, as Checkout's "Filmer rate (2 hrs)" shows.
    when 'hourly_street' then round(
           v_profile.hourly_rate_cents
           * extract(epoch from (v_request.ends_at - v_request.starts_at)) / 3600.0)::integer
    when 'park_drop_in'  then v_profile.park_drop_in_cents
    when 'full_edit'     then p_quote_cents
  end;

  if v_rate is null then
    raise exception 'set a price for this package before accepting it'
      using errcode = '22023';
  end if;

  if v_rate < 0 then
    raise exception 'a price cannot be negative' using errcode = '22023';
  end if;

  update public.filming_requests
     set status      = 'accepted',
         filmer_id   = v_user,
         accepted_at = now(),
         rate_cents  = v_rate
   where id = p_request_id;
end;
$$;

create or replace function public.pass_filming_request(p_request_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
begin
  if v_user is null or not public.is_bookable_filmer(v_user) then
    raise exception 'only an active filmer can pass on requests' using errcode = '42501';
  end if;

  if not exists (select 1 from public.filming_requests
                  where id = p_request_id and status = 'requested') then
    raise exception 'this request is no longer open' using errcode = '22023';
  end if;

  insert into public.filming_request_passes (request_id, filmer_id)
  values (p_request_id, v_user)
  on conflict do nothing;
end;
$$;

create or replace function public.cancel_filming_request(p_request_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user    uuid := auth.uid();
  v_request public.filming_requests%rowtype;
  v_by      public.request_party;
  v_late    boolean;
  v_fee     integer;
begin
  select * into v_request
    from public.filming_requests
   where id = p_request_id
     for update;

  if not found then
    raise exception 'no such request %', p_request_id using errcode = '22023';
  end if;

  if v_user = v_request.skater_id then
    v_by := 'skater';
  elsif v_user = v_request.filmer_id then
    v_by := 'filmer';
  else
    -- Includes a filmer trying to cancel a request they never accepted:
    -- that is what passing is for.
    raise exception 'only the skater or the accepted filmer can cancel'
      using errcode = '42501';
  end if;

  if v_request.status = 'cancelled' then
    raise exception 'this request is already cancelled' using errcode = '22023';
  end if;

  v_late := public.is_late_cancellation(v_request.starts_at, now());

  update public.filming_requests
     set status                = 'cancelled',
         cancelled_at          = now(),
         cancelled_by          = v_by,
         cancellation_was_late = v_late
   where id = p_request_id;

  if not v_late or v_request.status <> 'accepted' then
    -- Nothing is owed on time, and nothing is owed on a request nobody had
    -- accepted: no filmer had kept the slot, and there is no rate to take
    -- 15% of. It is still recorded as late, for the history.
    return;
  end if;

  if v_by = 'filmer' then
    -- A strike, capped at 3; the third pauses the profile. Pausing the
    -- capability too is what empties their Discover and hides them from
    -- skaters, and it flips profiles.filmer via the mirror trigger.
    update public.filmer_profiles
       set strike_count = least(strike_count + 1, 3),
           paused_at    = case when strike_count + 1 >= 3
                               then coalesce(paused_at, now()) else paused_at end
     where user_id = v_user;

    update public.profile_capabilities
       set status = 'paused'
     where user_id = v_user
       and capability = 'filmer'
       and status = 'active'
       and exists (select 1 from public.filmer_profiles
                    where user_id = v_user and strike_count >= 3);
  else
    -- 15% of the rate to Spot Check. Recorded as pending: collecting it
    -- (from the held charge, or off-session) is the Edge Function's job.
    v_fee := round(v_request.rate_cents * public.late_cancel_fee_basis_points() / 10000.0)::integer;

    insert into public.payments (
      kind, state, payer_id, payee_id, filming_request_id,
      subtotal_cents, fee_cents, fee_basis_points, fee_bearer,
      total_cents, payee_amount_cents
    ) values (
      'late_cancel_fee', 'pending', v_user, null, p_request_id,
      0, v_fee, public.late_cancel_fee_basis_points(), 'payer',
      v_fee, 0
    );
  end if;
end;
$$;

revoke all on function public.is_bookable_filmer(uuid) from public, anon;
grant execute on function public.is_bookable_filmer(uuid) to authenticated;

revoke all on function public.create_filming_request(
  public.filming_package, timestamptz, timestamptz, double precision, double precision,
  public.session_lighting, public.security_risk, uuid, text, text, uuid
) from public, anon;
grant execute on function public.create_filming_request(
  public.filming_package, timestamptz, timestamptz, double precision, double precision,
  public.session_lighting, public.security_risk, uuid, text, text, uuid
) to authenticated;

revoke all on function public.accept_filming_request(uuid, integer) from public, anon;
grant execute on function public.accept_filming_request(uuid, integer) to authenticated;

revoke all on function public.pass_filming_request(uuid) from public, anon;
grant execute on function public.pass_filming_request(uuid) to authenticated;

revoke all on function public.cancel_filming_request(uuid) from public, anon;
grant execute on function public.cancel_filming_request(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Row level security: read-only to clients
-- ---------------------------------------------------------------------------

alter table public.filming_requests       enable row level security;
alter table public.filming_request_passes enable row level security;

create policy "skaters read their own requests"
  on public.filming_requests for select to authenticated
  using (skater_id = auth.uid());

create policy "filmers read requests they accepted"
  on public.filming_requests for select to authenticated
  using (filmer_id = auth.uid());

-- Discover: open requests that haven't started, either sent to anyone or
-- named for me, that I haven't passed on -- and only while I'm bookable, so a
-- paused filmer's inbox is empty, as StrikePausedScreen says it is.
create policy "bookable filmers read open requests"
  on public.filming_requests for select to authenticated
  using (
    status = 'requested'
    and starts_at > now()
    and skater_id <> auth.uid()
    and (requested_filmer_id is null or requested_filmer_id = auth.uid())
    and public.is_bookable_filmer(auth.uid())
    and not exists (
      select 1 from public.filming_request_passes p
       where p.request_id = filming_requests.id and p.filmer_id = auth.uid()
    )
  );

create policy "filmers read their own passes"
  on public.filming_request_passes for select to authenticated
  using (filmer_id = auth.uid());

-- No insert/update/delete policies: writes go through the functions above.
