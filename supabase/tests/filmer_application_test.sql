-- The filmer application: who may apply, what applying records, and what
-- going live requires.
--
-- Alex, 2026-11-25: the applicant verifies their ID FIRST and waits for it to
-- be verified before the portfolio step. The app enforces the order; this
-- file pins that the database refuses an application from anyone who isn't a
-- verified adult, so a crafted request can't skip it either.
--
-- Run with `supabase test db` against a freshly reset local stack. Uses the
-- seed's skater (1111…, no identity verification at all) and adds:
--   7777…  a verified adult, not yet a filmer -- the happy path
--   8888…  verified by Stripe, but under 18
--   9999…  started verification, Stripe still processing
-- Everything runs in one transaction that is rolled back.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(21);

-- ---------------------------------------------------------------------------
-- Fixtures, inserted as postgres so they bypass RLS
-- ---------------------------------------------------------------------------

insert into auth.users (instance_id, id, aud, role, email, raw_user_meta_data)
values
  ('00000000-0000-0000-0000-000000000000', '77777777-7777-4777-8777-777777777777',
   'authenticated', 'authenticated', 'applicant@spotcheck.test', '{"username":"rider_diaz"}'),
  ('00000000-0000-0000-0000-000000000000', '88888888-8888-4888-8888-888888888888',
   'authenticated', 'authenticated', 'minor@spotcheck.test', '{"username":"rider_young"}'),
  ('00000000-0000-0000-0000-000000000000', '99999999-9999-4999-8999-999999999999',
   'authenticated', 'authenticated', 'pending@spotcheck.test', '{"username":"rider_wait"}');

-- The mirror trigger copies a verified row onto profiles, exactly as the
-- Stripe webhook's write would.
insert into public.identity_verifications
  (user_id, stripe_verification_session_id, status, verified_is_adult, verified_at)
values
  ('77777777-7777-4777-8777-777777777777', 'vs_test_applicant', 'verified', true, now()),
  ('88888888-8888-4888-8888-888888888888', 'vs_test_minor', 'verified', false, now()),
  ('99999999-9999-4999-8999-999999999999', 'vs_test_pending', 'processing', null, null);

-- ---------------------------------------------------------------------------
-- Who may apply
-- ---------------------------------------------------------------------------

select set_config('request.jwt.claims',
  '{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}', true);
set local role authenticated;

select throws_ok(
  $$select public.submit_filmer_application(
      array['VX1000 / tapeless'], array['Street follow-lines'],
      null, '11111111-1111-4111-8111-111111111111/raw.mov')$$,
  '22023', 'verify your ID before applying to film',
  'someone who never verified their ID cannot apply');

reset role;
select set_config('request.jwt.claims',
  '{"sub":"99999999-9999-4999-8999-999999999999","role":"authenticated"}', true);
set local role authenticated;

select throws_ok(
  $$select public.submit_filmer_application(
      array['VX1000 / tapeless'], array['Street follow-lines'],
      null, '99999999-9999-4999-8999-999999999999/raw.mov')$$,
  '22023', 'verify your ID before applying to film',
  'an ID Stripe is still processing is not enough: the applicant waits');

reset role;
select set_config('request.jwt.claims',
  '{"sub":"88888888-8888-4888-8888-888888888888","role":"authenticated"}', true);
set local role authenticated;

select throws_ok(
  $$select public.submit_filmer_application(
      array['VX1000 / tapeless'], array['Street follow-lines'],
      null, '88888888-8888-4888-8888-888888888888/raw.mov')$$,
  '22023', 'you must be 18 or older to film for Spot Check',
  'a verified ID that shows under 18 cannot apply');

reset role;
select is(
  (select count(*) from public.filmer_profiles
    where user_id in ('11111111-1111-4111-8111-111111111111',
                      '88888888-8888-4888-8888-888888888888',
                      '99999999-9999-4999-8999-999999999999')),
  0::bigint, 'a refused application leaves no filmer profile behind');

-- ---------------------------------------------------------------------------
-- What applying records (the verified adult)
-- ---------------------------------------------------------------------------

select set_config('request.jwt.claims',
  '{"sub":"77777777-7777-4777-8777-777777777777","role":"authenticated"}', true);
set local role authenticated;

select throws_ok(
  $$select public.submit_filmer_application(
      array['VX1000 / tapeless'], array['Street follow-lines'], null, '  ')$$,
  '22023', 'a raw follow-line clip is required',
  'the raw follow-line clip is still required');

select lives_ok(
  $$select public.submit_filmer_application(
      array['VX1000 / tapeless', 'External shotgun mic'], array['Street follow-lines'],
      null, '77777777-7777-4777-8777-777777777777/raw.mov')$$,
  'a verified adult can apply');

reset role;

select is(
  (select gear_review_status::text from public.filmer_profiles
    where user_id = '77777777-7777-4777-8777-777777777777'),
  'in_review', 'applying puts the gear and portfolio in review');

select is(
  (select background_check_status::text from public.filmer_profiles
    where user_id = '77777777-7777-4777-8777-777777777777'),
  'pending', 'applying leaves the background check pending');

select is(
  (select status::text from public.profile_capabilities
    where user_id = '77777777-7777-4777-8777-777777777777' and capability = 'filmer'),
  'in_review', 'applying puts the filmer capability in review');

select is(
  (select filmer from public.profiles where id = '77777777-7777-4777-8777-777777777777'),
  false, 'an applicant is not a filmer yet');

-- ---------------------------------------------------------------------------
-- What the applicant can and cannot write about themselves
-- ---------------------------------------------------------------------------

select set_config('request.jwt.claims',
  '{"sub":"77777777-7777-4777-8777-777777777777","role":"authenticated"}', true);
set local role authenticated;

select throws_ok(
  $$update public.filmer_profiles set background_check_status = 'passed'
     where user_id = '77777777-7777-4777-8777-777777777777'$$,
  '42501', null, 'an applicant cannot pass their own background check');

select throws_ok(
  $$update public.filmer_profiles set gear_review_status = 'passed'
     where user_id = '77777777-7777-4777-8777-777777777777'$$,
  '42501', null, 'an applicant cannot pass their own gear review');

select throws_ok(
  $$update public.filmer_profiles set consent_signed_at = now()
     where user_id = '77777777-7777-4777-8777-777777777777'$$,
  '42501', null, 'consent is recorded by the server, not written by the client');

select lives_ok(
  $$update public.filmer_profiles set hourly_rate_cents = 6000
     where user_id = '77777777-7777-4777-8777-777777777777'$$,
  'an applicant can set their own hourly rate');

-- ---------------------------------------------------------------------------
-- Going live
-- ---------------------------------------------------------------------------

select throws_ok(
  $$select public.filmer_go_live()$$,
  '22023', 'gear review and background check must both pass first',
  'nobody goes live while still in review');

reset role;
-- What the QA mock background check (or a person, in production) does.
update public.filmer_profiles
   set gear_review_status = 'passed', background_check_status = 'passed'
 where user_id = '77777777-7777-4777-8777-777777777777';

select set_config('request.jwt.claims',
  '{"sub":"77777777-7777-4777-8777-777777777777","role":"authenticated"}', true);
set local role authenticated;

update public.filmer_profiles set hourly_rate_cents = null
 where user_id = '77777777-7777-4777-8777-777777777777';

select throws_ok(
  $$select public.filmer_go_live()$$,
  '22023', 'set an hourly rate before going live',
  'going live needs an hourly rate');

update public.filmer_profiles set hourly_rate_cents = 6000, park_drop_in_cents = 4000
 where user_id = '77777777-7777-4777-8777-777777777777';

select lives_ok($$select public.filmer_go_live()$$,
  'with ID verified, both checks passed and a rate set, the applicant goes live');

reset role;

select is(
  (select status::text from public.profile_capabilities
    where user_id = '77777777-7777-4777-8777-777777777777' and capability = 'filmer'),
  'active', 'going live activates the filmer capability');

select is(
  (select filmer from public.profiles where id = '77777777-7777-4777-8777-777777777777'),
  true, 'going live makes them a filmer on their profile');

select isnt(
  (select went_live_at from public.filmer_profiles
    where user_id = '77777777-7777-4777-8777-777777777777'),
  null, 'going live is timestamped');

-- A live filmer editing their portfolio stays live (re-applying never demotes).
select set_config('request.jwt.claims',
  '{"sub":"77777777-7777-4777-8777-777777777777","role":"authenticated"}', true);
set local role authenticated;
select public.submit_filmer_application(
  array['VX1000 / tapeless'], array['Night / external lighting'],
  null, '77777777-7777-4777-8777-777777777777/raw2.mov');
reset role;

select is(
  (select status::text from public.profile_capabilities
    where user_id = '77777777-7777-4777-8777-777777777777' and capability = 'filmer'),
  'active', 'a live filmer who re-submits their portfolio stays live');

select * from finish();

rollback;
