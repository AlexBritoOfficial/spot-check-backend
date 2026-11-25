-- Applying to film now requires a verified adult ID, first.
--
-- Alex, 2026-11-25: in the "Earn with Spot Check" flow the applicant verifies
-- their ID FIRST and waits for Stripe's answer before the portfolio step:
--   ProApply -> IDVerify -> FilmerQualify -> Verification -> FilmerRates -> live
-- This replaces the order 20261124120004's header comment records (ID after
-- the portfolio), which is the canvas's.
--
-- The app enforces the order; this makes the database refuse an application
-- from anyone who isn't a verified adult, so a crafted request can't skip it
-- -- the same "the client decides when to ask, the database decides whether
-- the answer is yes" rule as filmer_go_live. "Still processing" is not enough.
--
-- Everything else is unchanged from 20261124120004. Same signature, so the
-- existing grant to authenticated carries over.

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
  v_user     uuid := auth.uid();
  v_id_at    timestamptz;
  v_is_adult boolean;
begin
  if v_user is null then
    raise exception 'must be signed in to apply' using errcode = '28000';
  end if;

  -- Mirrored from identity_verifications by trigger, only on 'verified', so a
  -- session Stripe is still processing leaves identity_verified_at null.
  select p.identity_verified_at, p.identity_is_adult
    into v_id_at, v_is_adult
    from public.profiles p
   where p.id = v_user;

  if v_id_at is null then
    raise exception 'verify your ID before applying to film' using errcode = '22023';
  end if;

  -- A distinct message, so the app can stop the flow rather than offer a retry.
  if v_is_adult is not true then
    raise exception 'you must be 18 or older to film for Spot Check' using errcode = '22023';
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
