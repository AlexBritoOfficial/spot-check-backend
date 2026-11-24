-- Industry accounts: organizations, membership and invite codes.
--
-- Industry is not a flat flag on a person. Portfolio/ProfileVisitsScreen.swift:23
-- states the rule: "Industry accounts are invite-only and tied to a verified
-- shop or brand." And the canvas distinguishes a named human acting for an org
-- -- ProfileVisitsScreen.swift:124 shows "Low Tide Wheels - Brand · team
-- manager" -- so membership carries a title.
--
-- Shops first; 'brand' exists in the enum because Opportunities already draws
-- both, but nothing onboards a brand yet.

create type public.organization_kind as enum ('shop', 'brand');

create table public.organizations (
  id             uuid primary key default gen_random_uuid(),
  kind           public.organization_kind not null,
  name           text not null,
  -- Where an invite code is sent. Verifying the shop means proving control of
  -- its published address, so this is the org's own public email, not a
  -- member's personal one.
  official_email text not null,
  verified_at    timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

-- Same lower() idiom as profiles_home_city_idx, so one shop can't be
-- onboarded twice under different casing.
create unique index organizations_official_email_key
  on public.organizations (lower(official_email));

create trigger organizations_touch_updated_at
  before update on public.organizations
  for each row execute function public.touch_updated_at();

create table public.organization_members (
  organization_id uuid not null references public.organizations(id) on delete cascade,
  user_id         uuid not null references public.profiles(id) on delete cascade,
  -- "team manager", "buyer" -- shown beside the org name on ProfileVisits.
  title           text,
  created_at      timestamptz not null default now(),
  primary key (organization_id, user_id)
);

create index organization_members_user_idx
  on public.organization_members (user_id);

-- Invite codes are stored hashed and the table gets no policies at all, so a
-- code is never selectable by any client -- redeeming goes through the
-- definer RPC below, which is the only thing that can see one. sha256() is
-- built into Postgres; no extension needed.
create table public.organization_invites (
  code_hash       text primary key,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  email           text not null,
  expires_at      timestamptz not null,
  redeemed_at     timestamptz,
  redeemed_by     uuid references public.profiles(id) on delete set null,
  created_at      timestamptz not null default now()
);

create index organization_invites_org_idx
  on public.organization_invites (organization_id);

create or replace function public.hash_invite_code(p_code text)
returns text
language sql
immutable
set search_path = ''
as $$
  select encode(sha256(convert_to(upper(trim(p_code)), 'UTF8')), 'hex');
$$;

-- Redeeming is the *only* way to obtain the industry capability. A client has
-- no write access to profile_capabilities, so this definer function is the
-- entire grant path -- which is what makes "invite-only" actually true rather
-- than a UI convention.
create or replace function public.redeem_organization_invite(p_code text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user   uuid := auth.uid();
  v_invite public.organization_invites%rowtype;
begin
  if v_user is null then
    raise exception 'must be signed in to redeem an invite'
      using errcode = '28000';
  end if;

  select * into v_invite
    from public.organization_invites i
   where i.code_hash = public.hash_invite_code(p_code)
   for update;

  -- One message for "no such code" and "already used" on purpose: telling them
  -- apart lets someone probe for valid codes.
  if not found or v_invite.redeemed_at is not null then
    raise exception 'invite code is not valid' using errcode = '22023';
  end if;

  if v_invite.expires_at <= now() then
    raise exception 'invite code has expired' using errcode = '22023';
  end if;

  update public.organization_invites
     set redeemed_at = now(),
         redeemed_by = v_user
   where code_hash = v_invite.code_hash;

  insert into public.organization_members (organization_id, user_id)
  values (v_invite.organization_id, v_user)
  on conflict (organization_id, user_id) do nothing;

  insert into public.profile_capabilities (user_id, capability, status, granted_at)
  values (v_user, 'industry', 'active', now())
  on conflict (user_id, capability) do update
    set status     = 'active',
        granted_at = now(),
        revoked_at = null;

  return v_invite.organization_id;
end;
$$;

revoke all on function public.redeem_organization_invite(text) from public, anon;
grant execute on function public.redeem_organization_invite(text) to authenticated;
