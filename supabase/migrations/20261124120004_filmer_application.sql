-- The filmer application flow, as the canvas draws it:
--   ProApply -> FilmerQualify -> IDVerify -> Verification -> FilmerRates -> live
--
-- Both functions are security definer because the client has no write access to
-- profile_capabilities, and because the go-live gate has to be enforced where
-- it cannot be skipped. The client decides when to *ask*; the database decides
-- whether the answer is yes.

create or replace function public.submit_filmer_application(
  p_gear      text[],
  p_styles    text[],
  p_reel_path text,
  p_raw_clip_path text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
begin
  if v_user is null then
    raise exception 'must be signed in to apply' using errcode = '28000';
  end if;

  -- FilmerQualifyScreen marks the raw follow-line clip "Required": it is the
  -- one piece of evidence that shows a steady frame at speed.
  if p_raw_clip_path is null or length(trim(p_raw_clip_path)) = 0 then
    raise exception 'a raw follow-line clip is required' using errcode = '22023';
  end if;

  insert into public.filmer_profiles (
    user_id, gear, styles, reel_path, raw_clip_path,
    gear_review_status, background_check_status
  )
  values (
    v_user, coalesce(p_gear, '{}'), coalesce(p_styles, '{}'), p_reel_path, p_raw_clip_path,
    'in_review', 'pending'
  )
  on conflict (user_id) do update
    set gear               = excluded.gear,
        styles             = excluded.styles,
        reel_path          = excluded.reel_path,
        raw_clip_path      = excluded.raw_clip_path,
        gear_review_status = 'in_review';

  insert into public.profile_capabilities (user_id, capability, status)
  values (v_user, 'filmer', 'in_review')
  on conflict (user_id, capability) do update
    set status = (case
                   -- Re-applying never silently demotes a filmer who is
                   -- already live and just editing their portfolio.
                   when public.profile_capabilities.status = 'active' then 'active'
                   else 'in_review'
                 end)::public.capability_status;
end;
$$;

revoke all on function public.submit_filmer_application(text[], text[], text, text)
  from public, anon;
grant execute on function public.submit_filmer_application(text[], text[], text, text)
  to authenticated;

-- "Set rates & go live" is drawn as locked until the checks pass
-- (VerificationScreen). The client honours that, but the rule lives here so a
-- crafted request cannot go live anyway.
create or replace function public.filmer_go_live()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user    uuid := auth.uid();
  v_profile public.filmer_profiles%rowtype;
  v_adult   boolean;
  v_id_at   timestamptz;
begin
  if v_user is null then
    raise exception 'must be signed in' using errcode = '28000';
  end if;

  select * into v_profile from public.filmer_profiles where user_id = v_user;
  if not found then
    raise exception 'no filmer application found' using errcode = '22023';
  end if;

  select p.identity_is_adult, p.identity_verified_at
    into v_adult, v_id_at
    from public.profiles p where p.id = v_user;

  -- Every filmer gets paid, so IDVerify's rule applies: "Everyone who books,
  -- pays or gets paid verifies once", and Spot Check is 18+.
  if v_id_at is null or v_adult is not true then
    raise exception 'identity must be verified before going live'
      using errcode = '22023';
  end if;

  if v_profile.gear_review_status <> 'passed'
     or v_profile.background_check_status <> 'passed' then
    raise exception 'gear review and background check must both pass first'
      using errcode = '22023';
  end if;

  if v_profile.paused_at is not null then
    raise exception 'profile is paused' using errcode = '22023';
  end if;

  if v_profile.hourly_rate_cents is null then
    raise exception 'set an hourly rate before going live' using errcode = '22023';
  end if;

  update public.filmer_profiles
     set went_live_at = coalesce(went_live_at, now())
   where user_id = v_user;

  insert into public.profile_capabilities (user_id, capability, status, granted_at)
  values (v_user, 'filmer', 'active', now())
  on conflict (user_id, capability) do update
    set status     = 'active',
        granted_at = coalesce(public.profile_capabilities.granted_at, now()),
        revoked_at = null;
end;
$$;

revoke all on function public.filmer_go_live() from public, anon;
grant execute on function public.filmer_go_live() to authenticated;
