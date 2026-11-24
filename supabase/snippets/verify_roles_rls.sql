-- Proves the privilege rules hold. Run against a freshly reset local stack:
--
--   supabase db reset
--   docker cp supabase/snippets/verify_roles_rls.sql \
--     supabase_db_spot-check-iOS:/tmp/v.sql
--   docker exec -i supabase_db_spot-check-iOS \
--     psql -U postgres -d postgres -f /tmp/v.sql
--
-- Every block is expected to FAIL except the ones marked otherwise -- an
-- unexpected success here is a privilege-escalation hole. Sections 1 and 2
-- would both have passed silently before the column GRANTs were added, which
-- is the regression this file exists to catch.
--
-- Depends on the fixtures in seed.sql. Every statement runs in a transaction
-- that is rolled back, so it leaves the database as it found it.

\set ON_ERROR_STOP off
\pset pager off

-- Act as the plain skater fixture.
create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claim.sub', p::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role','authenticated')::text, true);
end $$;

\echo '=============================================================='
\echo '1. ESCALATION: a plain skater must not promote themselves'
\echo '=============================================================='

begin;
select pg_temp.as_user('11111111-1111-4111-8111-111111111111');
\echo '-- 1a. set filmer = true on self  (EXPECT: permission denied)'
update public.profiles set filmer = true where id = auth.uid();
rollback;

begin;
select pg_temp.as_user('11111111-1111-4111-8111-111111111111');
\echo '-- 1b. set identity_is_adult = true on self  (EXPECT: permission denied)'
update public.profiles set identity_is_adult = true where id = auth.uid();
rollback;

begin;
select pg_temp.as_user('11111111-1111-4111-8111-111111111111');
\echo '-- 1c. set identity_verified_at on self  (EXPECT: permission denied)'
update public.profiles set identity_verified_at = now() where id = auth.uid();
rollback;

begin;
select pg_temp.as_user('11111111-1111-4111-8111-111111111111');
\echo '-- 1d. grant self a capability  (EXPECT: 0 rows / denied)'
insert into public.profile_capabilities (user_id, capability, status)
values (auth.uid(), 'filmer', 'active');
rollback;

begin;
select pg_temp.as_user('11111111-1111-4111-8111-111111111111');
\echo '-- 1e. activate an existing capability row  (EXPECT: UPDATE 0)'
update public.profile_capabilities set status = 'active';
rollback;

\echo ''
\echo '=============================================================='
\echo '2. ESCALATION: a filmer must not pass their own checks'
\echo '=============================================================='

begin;
select pg_temp.as_user('22222222-2222-4222-8222-222222222222');
\echo '-- 2a. pass own background check  (EXPECT: permission denied)'
update public.filmer_profiles set background_check_status = 'passed' where user_id = auth.uid();
rollback;

begin;
select pg_temp.as_user('33333333-3333-4333-8333-333333333333');
\echo '-- 2b. paused filmer clears own strikes  (EXPECT: permission denied)'
update public.filmer_profiles set strike_count = 0, paused_at = null where user_id = auth.uid();
rollback;

begin;
select pg_temp.as_user('22222222-2222-4222-8222-222222222222');
\echo '-- 2c. filmer edits own rate  (EXPECT: UPDATE 1 -- this one is allowed)'
update public.filmer_profiles set hourly_rate_cents = 7000 where user_id = auth.uid();
rollback;

\echo ''
\echo '=============================================================='
\echo '3. MONEY: clients must not write payment state'
\echo '=============================================================='

begin;
select pg_temp.as_user('22222222-2222-4222-8222-222222222222');
\echo '-- 3a. payee releases own held payment  (EXPECT: UPDATE 0 / denied)'
update public.payments set state = 'released'
 where id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1';
rollback;

begin;
select pg_temp.as_user('22222222-2222-4222-8222-222222222222');
\echo '-- 3b. call record_payment_event directly  (EXPECT: permission denied)'
select public.record_payment_event('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1', 'released', 'nope');
rollback;

\echo ''
\echo '=============================================================='
\echo '4. VISIBILITY'
\echo '=============================================================='

begin;
select pg_temp.as_user('44444444-4444-4444-8444-444444444444');
\echo '-- 4a. uninvolved user reads payments  (EXPECT: 0)'
select count(*) as visible_payments from public.payments;
\echo '-- 4b. anyone reads invite codes  (EXPECT: 0)'
select count(*) as visible_invites from public.organization_invites;
rollback;

begin;
select pg_temp.as_user('11111111-1111-4111-8111-111111111111');
\echo '-- 4c. payer reads own payments  (EXPECT: 4)'
select count(*) as my_payments from public.payments;
\echo '-- 4d. skater reads capabilities (public badges)  (EXPECT: 4)'
select count(*) as visible_capabilities from public.profile_capabilities;
\echo '-- 4e. skater reads someone else identity verification  (EXPECT: 0)'
select count(*) as other_identity from public.identity_verifications;
rollback;

\echo ''
\echo '=============================================================='
\echo '5. GO-LIVE GATE is server-side'
\echo '=============================================================='

begin;
select pg_temp.as_user('11111111-1111-4111-8111-111111111111');
\echo '-- 5a. skater with no application goes live  (EXPECT: no filmer application found)'
select public.filmer_go_live();
rollback;

begin;
\echo '-- 5b. applicant whose checks are pending goes live (EXPECT: checks must pass)'
select pg_temp.as_user('11111111-1111-4111-8111-111111111111');
select public.submit_filmer_application(
  array['VX1000 / tapeless'], array['Street follow-lines'], null, 'x/raw.mp4');
select public.filmer_go_live();
rollback;

begin;
\echo '-- 5c. application without the required raw clip (EXPECT: raw follow-line clip is required)'
select pg_temp.as_user('11111111-1111-4111-8111-111111111111');
select public.submit_filmer_application(array['VX1000'], array['Street'], null, null);
rollback;

\echo ''
\echo '=============================================================='
\echo '6. INVITE CODES are single-use'
\echo '=============================================================='

begin;
select pg_temp.as_user('11111111-1111-4111-8111-111111111111');
\echo '-- 6a. redeem a valid code  (EXPECT: returns the org id)'
select public.redeem_organization_invite('SPOTCHECK-BRICKTOWN') as org;
\echo '-- 6b. industry capability now active  (EXPECT: active)'
select status from public.profile_capabilities
 where user_id = auth.uid() and capability = 'industry';
\echo '-- 6c. redeem the same code again  (EXPECT: invite code is not valid)'
select public.redeem_organization_invite('SPOTCHECK-BRICKTOWN');
rollback;

begin;
select pg_temp.as_user('11111111-1111-4111-8111-111111111111');
\echo '-- 6d. redeem a made-up code  (EXPECT: invite code is not valid)'
select public.redeem_organization_invite('TOTALLY-FAKE');
rollback;

\echo ''
\echo '=============================================================='
\echo '7. DERIVED profiles.filmer mirror'
\echo '=============================================================='
\echo '-- EXPECT: filmer t, paused f, skater f'
select p.username, p.filmer, p.identity_is_adult
  from public.profiles p
 where p.username in ('rider_okafor','rider_silva','rider_nguyen')
 order by p.username;

\echo ''
\echo '-- EXPECT: fee model consistent for both kinds'
select kind, fee_bearer, subtotal_cents, fee_cents, total_cents, payee_amount_cents
  from public.payments order by kind, total_cents;
