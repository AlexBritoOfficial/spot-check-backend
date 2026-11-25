-- Filming requests: who can create, see, accept, pass on and cancel a
-- request, and what a late cancellation costs each side.
--
-- Run with `supabase test db` against a freshly reset local stack. Relies on
-- the seed's five role fixtures (seed.sql):
--   1111… skater  -- plain skater, the one who books
--   2222… filmer  -- active, $60/hr, $40 park drop-in
--   3333… paused  -- filmer capability paused at 3 strikes
--   4444… shop    -- industry, not a filmer
-- and adds a second active filmer (6666…) so "only the named filmer" and
-- "a pass hides it from me only" have someone else to compare against.
--
-- Everything runs in one transaction that is rolled back, so now() is a fixed
-- instant throughout and "starts in 3 hours" means exactly that.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(60);

-- ---------------------------------------------------------------------------
-- Fixtures, inserted as postgres so they bypass RLS
-- ---------------------------------------------------------------------------

insert into auth.users (instance_id, id, aud, role, email, raw_user_meta_data)
values ('00000000-0000-0000-0000-000000000000',
        '66666666-6666-4666-8666-666666666666', 'authenticated', 'authenticated',
        'filmer2@spotcheck.test', '{"username":"rider_park"}');

insert into public.filmer_profiles
  (user_id, hourly_rate_cents, gear_review_status, background_check_status, went_live_at)
values ('66666666-6666-4666-8666-666666666666', 5000, 'passed', 'passed', now());

insert into public.profile_capabilities (user_id, capability, status, granted_at)
values ('66666666-6666-4666-8666-666666666666', 'filmer', 'active', now());

-- Requests. Coordinates are Copley Square's; only the times and parties vary.
insert into public.filming_requests
  (id, skater_id, requested_filmer_id, package, lat, lng,
   starts_at, ends_at, lighting, security_risk)
values
  -- open to any filmer, two days out, 2 hours
  ('f0000000-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111', null,
   'hourly_street', 42.3493, -71.0767,
   now() + interval '2 days', now() + interval '2 days 2 hours', 'golden_hour', 'sometimes'),
  -- named for filmer 2222 only
  ('f0000000-0000-4000-8000-000000000002', '11111111-1111-4111-8111-111111111111',
   '22222222-2222-4222-8222-222222222222',
   'hourly_street', 42.3493, -71.0767,
   now() + interval '3 days', now() + interval '3 days 2 hours', 'daylight', 'low'),
  -- park drop-in: a flat price, whatever the length
  ('f0000000-0000-4000-8000-000000000003', '11111111-1111-4111-8111-111111111111', null,
   'park_drop_in', 42.3730, -71.0760,
   now() + interval '2 days', now() + interval '2 days 1 hour', 'daylight', 'low'),
  -- full edit: quoted on request
  ('f0000000-0000-4000-8000-000000000004', '11111111-1111-4111-8111-111111111111', null,
   'full_edit', 42.3493, -71.0767,
   now() + interval '4 days', now() + interval '4 days 8 hours', 'daylight', 'low'),
  -- open, starting inside the 5-hour window, never accepted
  ('f0000000-0000-4000-8000-000000000005', '11111111-1111-4111-8111-111111111111', null,
   'hourly_street', 42.3493, -71.0767,
   now() + interval '3 hours', now() + interval '5 hours', 'night', 'low'),
  -- already started: nobody can pick it up any more
  ('f0000000-0000-4000-8000-000000000012', '11111111-1111-4111-8111-111111111111', null,
   'hourly_street', 42.3493, -71.0767,
   now() - interval '1 hour', now() + interval '1 hour', 'daylight', 'low');

-- Accepted by filmer 2222 at $120 (2 hrs at $60).
insert into public.filming_requests
  (id, skater_id, filmer_id, package, lat, lng, starts_at, ends_at,
   lighting, security_risk, status, accepted_at, rate_cents)
values
  -- three late ones for the strike ladder
  ('f0000000-0000-4000-8000-000000000006', '11111111-1111-4111-8111-111111111111',
   '22222222-2222-4222-8222-222222222222', 'hourly_street', 42.3493, -71.0767,
   now() + interval '1 hour', now() + interval '3 hours', 'daylight', 'low',
   'accepted', now(), 12000),
  ('f0000000-0000-4000-8000-000000000007', '11111111-1111-4111-8111-111111111111',
   '22222222-2222-4222-8222-222222222222', 'hourly_street', 42.3493, -71.0767,
   now() + interval '2 hours', now() + interval '4 hours', 'daylight', 'low',
   'accepted', now(), 12000),
  ('f0000000-0000-4000-8000-000000000008', '11111111-1111-4111-8111-111111111111',
   '22222222-2222-4222-8222-222222222222', 'hourly_street', 42.3493, -71.0767,
   now() + interval '4 hours', now() + interval '6 hours', 'daylight', 'low',
   'accepted', now(), 12000),
  -- filmer cancels in good time
  ('f0000000-0000-4000-8000-000000000009', '11111111-1111-4111-8111-111111111111',
   '22222222-2222-4222-8222-222222222222', 'hourly_street', 42.3493, -71.0767,
   now() + interval '2 days', now() + interval '2 days 2 hours', 'daylight', 'low',
   'accepted', now(), 12000),
  -- skater cancels late
  ('f0000000-0000-4000-8000-000000000010', '11111111-1111-4111-8111-111111111111',
   '22222222-2222-4222-8222-222222222222', 'hourly_street', 42.3493, -71.0767,
   now() + interval '3 hours', now() + interval '5 hours', 'daylight', 'low',
   'accepted', now(), 12000),
  -- skater cancels in good time
  ('f0000000-0000-4000-8000-000000000011', '11111111-1111-4111-8111-111111111111',
   '22222222-2222-4222-8222-222222222222', 'hourly_street', 42.3493, -71.0767,
   now() + interval '2 days', now() + interval '2 days 2 hours', 'daylight', 'low',
   'accepted', now(), 12000);

-- ---------------------------------------------------------------------------
-- Shape
-- ---------------------------------------------------------------------------

select has_table('public', 'filming_requests', 'filming_requests exists');
select has_table('public', 'filming_request_passes', 'filming_request_passes exists');
select has_column('public', 'payments', 'filming_request_id',
  'a payment can point at the request it pays for');

-- ---------------------------------------------------------------------------
-- The 5-hour rule (Alex, 2026-11-24): late = less than 5 hours before start
-- ---------------------------------------------------------------------------

select is(public.is_late_cancellation(now() + interval '4 hours 59 minutes', now()), true,
  '4h59m before the start is late');
select is(public.is_late_cancellation(now() + interval '5 hours 1 minute', now()), false,
  '5h01m before the start is on time');
select is(public.is_late_cancellation(now() + interval '5 hours', now()), false,
  'exactly 5 hours before the start is on time');
select is(public.is_late_cancellation(now() - interval '10 minutes', now()), true,
  'cancelling after the start is late');

-- ---------------------------------------------------------------------------
-- Creating a request
-- ---------------------------------------------------------------------------

select set_config('request.jwt.claims',
  '{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}', true);
set local role authenticated;

select isnt(
  public.create_filming_request(
    'hourly_street', now() + interval '1 day', now() + interval '1 day 2 hours',
    42.3493, -71.0767, 'golden_hour', 'sometimes'),
  null, 'a skater can create a request');

select is(
  (select status::text from public.filming_requests
    where skater_id = '11111111-1111-4111-8111-111111111111'
      and starts_at = now() + interval '1 day'),
  'requested', 'a new request starts as requested and its skater can see it');

select throws_ok(
  $$select public.create_filming_request(
      'hourly_street', now() - interval '1 hour', now() + interval '1 hour',
      42.3493, -71.0767, 'daylight', 'low')$$,
  '22023', null, 'a request cannot start in the past');

select throws_ok(
  $$select public.create_filming_request(
      'hourly_street', now() + interval '1 day 2 hours', now() + interval '1 day',
      42.3493, -71.0767, 'daylight', 'low')$$,
  '22023', null, 'a request must end after it starts');

select throws_ok(
  $$select public.create_filming_request(
      'hourly_street', now() + interval '1 day', now() + interval '1 day 2 hours',
      42.3493, -71.0767, 'daylight', 'low',
      p_requested_filmer_id => '44444444-4444-4444-8444-444444444444')$$,
  '22023', null, 'a request can only be named for an active filmer');

select throws_ok(
  $$insert into public.filming_requests
      (skater_id, package, lat, lng, starts_at, ends_at, lighting, security_risk)
    values ('11111111-1111-4111-8111-111111111111', 'hourly_street', 42.35, -71.07,
            now() + interval '1 day', now() + interval '1 day 1 hour', 'daylight', 'low')$$,
  '42501', null, 'clients cannot insert requests directly');

select results_eq(
  $$with changed as (
      update public.filming_requests set status = 'accepted'
       where id = 'f0000000-0000-4000-8000-000000000001' returning 1)
    select count(*)::int from changed$$,
  $$values (0)$$, 'clients cannot update a request directly');

reset role;

-- ---------------------------------------------------------------------------
-- Who sees what
-- ---------------------------------------------------------------------------

-- filmer 2222
select set_config('request.jwt.claims',
  '{"sub":"22222222-2222-4222-8222-222222222222","role":"authenticated"}', true);
set local role authenticated;

select ok(exists(select 1 from public.filming_requests
                  where id = 'f0000000-0000-4000-8000-000000000001'),
  'an active filmer sees an open request');
select ok(exists(select 1 from public.filming_requests
                  where id = 'f0000000-0000-4000-8000-000000000002'),
  'the named filmer sees a request named for them');
select ok(not exists(select 1 from public.filming_requests
                      where id = 'f0000000-0000-4000-8000-000000000012'),
  'a request that has already started is no longer offered');

reset role;

-- filmer 6666
select set_config('request.jwt.claims',
  '{"sub":"66666666-6666-4666-8666-666666666666","role":"authenticated"}', true);
set local role authenticated;

select ok(exists(select 1 from public.filming_requests
                  where id = 'f0000000-0000-4000-8000-000000000001'),
  'every active filmer sees an open request');
select ok(not exists(select 1 from public.filming_requests
                      where id = 'f0000000-0000-4000-8000-000000000002'),
  'other filmers do not see a request named for someone else');
select ok(not exists(select 1 from public.filming_requests
                      where id = 'f0000000-0000-4000-8000-000000000006'),
  'other filmers do not see a request someone else accepted');

reset role;

-- paused filmer 3333
select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-4333-8333-333333333333","role":"authenticated"}', true);
set local role authenticated;

select ok(not exists(select 1 from public.filming_requests
                      where id = 'f0000000-0000-4000-8000-000000000001'),
  'a paused filmer sees no open requests (StrikePaused: "Your Discover inbox is empty")');

reset role;

-- shop 4444
select set_config('request.jwt.claims',
  '{"sub":"44444444-4444-4444-8444-444444444444","role":"authenticated"}', true);
set local role authenticated;

select ok(not exists(select 1 from public.filming_requests
                      where id = 'f0000000-0000-4000-8000-000000000001'),
  'someone who is not a filmer sees no open requests');

reset role;

-- ---------------------------------------------------------------------------
-- Passing
-- ---------------------------------------------------------------------------

select set_config('request.jwt.claims',
  '{"sub":"22222222-2222-4222-8222-222222222222","role":"authenticated"}', true);
set local role authenticated;

select lives_ok(
  $$select public.pass_filming_request('f0000000-0000-4000-8000-000000000001')$$,
  'a filmer can pass on an open request');
select ok(not exists(select 1 from public.filming_requests
                      where id = 'f0000000-0000-4000-8000-000000000001'),
  'a passed request leaves that filmer''s Discover');
select lives_ok(
  $$select public.pass_filming_request('f0000000-0000-4000-8000-000000000001')$$,
  'passing twice is harmless');

reset role;

select set_config('request.jwt.claims',
  '{"sub":"66666666-6666-4666-8666-666666666666","role":"authenticated"}', true);
set local role authenticated;

select ok(exists(select 1 from public.filming_requests
                  where id = 'f0000000-0000-4000-8000-000000000001'),
  'one filmer passing does not hide the request from others');

reset role;

select set_config('request.jwt.claims',
  '{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}', true);
set local role authenticated;

select is(
  (select status::text from public.filming_requests
    where id = 'f0000000-0000-4000-8000-000000000001'),
  'requested', 'a pass does not change the request for the skater');

-- ---------------------------------------------------------------------------
-- Accepting
-- ---------------------------------------------------------------------------

select throws_ok(
  $$select public.accept_filming_request('f0000000-0000-4000-8000-000000000003')$$,
  '42501', null, 'a skater cannot accept a request (they are not a filmer)');

reset role;

select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-4333-8333-333333333333","role":"authenticated"}', true);
set local role authenticated;

select throws_ok(
  $$select public.accept_filming_request('f0000000-0000-4000-8000-000000000003')$$,
  '42501', null, 'a paused filmer cannot accept');

reset role;

select set_config('request.jwt.claims',
  '{"sub":"66666666-6666-4666-8666-666666666666","role":"authenticated"}', true);
set local role authenticated;

select throws_ok(
  $$select public.accept_filming_request('f0000000-0000-4000-8000-000000000002')$$,
  '42501', null, 'only the named filmer can accept a named request');

select lives_ok(
  $$select public.accept_filming_request('f0000000-0000-4000-8000-000000000001')$$,
  'an active filmer can accept an open request');

select results_eq(
  $$select status::text, filmer_id, rate_cents, accepted_at is not null
      from public.filming_requests where id = 'f0000000-0000-4000-8000-000000000001'$$,
  $$values ('accepted', '66666666-6666-4666-8666-666666666666'::uuid, 10000, true)$$,
  'accepting records the filmer and prices 2 hours at their own $50/hr');

reset role;

select set_config('request.jwt.claims',
  '{"sub":"22222222-2222-4222-8222-222222222222","role":"authenticated"}', true);
set local role authenticated;

select throws_ok(
  $$select public.accept_filming_request('f0000000-0000-4000-8000-000000000001')$$,
  '22023', null, 'the first filmer to accept wins; a second accept is refused');

select throws_ok(
  $$select public.accept_filming_request('f0000000-0000-4000-8000-000000000012')$$,
  '22023', null, 'a request that has already started cannot be accepted');

select lives_ok(
  $$select public.accept_filming_request('f0000000-0000-4000-8000-000000000002')$$,
  'the named filmer can accept their request');

select lives_ok(
  $$select public.accept_filming_request('f0000000-0000-4000-8000-000000000003')$$,
  'a filmer can accept a park drop-in');
select is(
  (select rate_cents from public.filming_requests
    where id = 'f0000000-0000-4000-8000-000000000003'),
  4000, 'a park drop-in is the filmer''s flat drop-in price');

select throws_ok(
  $$select public.accept_filming_request('f0000000-0000-4000-8000-000000000004')$$,
  '22023', null, 'a full edit cannot be accepted without a quote');
select lives_ok(
  $$select public.accept_filming_request('f0000000-0000-4000-8000-000000000004', 75000)$$,
  'a full edit can be accepted with a quote');
select is(
  (select rate_cents from public.filming_requests
    where id = 'f0000000-0000-4000-8000-000000000004'),
  75000, 'a full edit is priced at the quote');

-- ---------------------------------------------------------------------------
-- Filmer cancellations: late ones are strikes, the third pauses the profile
-- ---------------------------------------------------------------------------

select throws_ok(
  $$select public.cancel_filming_request('f0000000-0000-4000-8000-000000000005')$$,
  '42501', null, 'a filmer cannot cancel a request they have not accepted (they pass)');

select lives_ok(
  $$select public.cancel_filming_request('f0000000-0000-4000-8000-000000000009')$$,
  'a filmer can cancel an accepted request in good time');

reset role;

select results_eq(
  $$select status::text, cancelled_by::text, cancellation_was_late
      from public.filming_requests where id = 'f0000000-0000-4000-8000-000000000009'$$,
  $$values ('cancelled', 'filmer', false)$$,
  'an on-time filmer cancellation is recorded as not late');
select is(
  (select strike_count from public.filmer_profiles
    where user_id = '22222222-2222-4222-8222-222222222222'),
  0, 'an on-time filmer cancellation is not a strike');

select set_config('request.jwt.claims',
  '{"sub":"22222222-2222-4222-8222-222222222222","role":"authenticated"}', true);
set local role authenticated;

select lives_ok(
  $$select public.cancel_filming_request('f0000000-0000-4000-8000-000000000006')$$,
  'a filmer can cancel late');

reset role;

select results_eq(
  $$select strike_count, paused_at is null from public.filmer_profiles
     where user_id = '22222222-2222-4222-8222-222222222222'$$,
  $$values (1, true)$$, 'a late filmer cancellation is one strike, not yet a pause');

select set_config('request.jwt.claims',
  '{"sub":"22222222-2222-4222-8222-222222222222","role":"authenticated"}', true);
set local role authenticated;

select public.cancel_filming_request('f0000000-0000-4000-8000-000000000007');
select public.cancel_filming_request('f0000000-0000-4000-8000-000000000008');

reset role;

select results_eq(
  $$select fp.strike_count, fp.paused_at is not null, pc.status::text, p.filmer
      from public.filmer_profiles fp
      join public.profile_capabilities pc
        on pc.user_id = fp.user_id and pc.capability = 'filmer'
      join public.profiles p on p.id = fp.user_id
     where fp.user_id = '22222222-2222-4222-8222-222222222222'$$,
  $$values (3, true, 'paused', false)$$,
  'the third late cancellation pauses the filmer profile and capability');

select is(
  (select count(*)::int from public.payments
    where filming_request_id in ('f0000000-0000-4000-8000-000000000006',
                                 'f0000000-0000-4000-8000-000000000007',
                                 'f0000000-0000-4000-8000-000000000008')),
  0, 'a filmer''s late cancellation charges nobody a fee (the skater is refunded)');

-- ---------------------------------------------------------------------------
-- Skater cancellations: late ones cost 15% of the rate, paid to Spot Check
-- ---------------------------------------------------------------------------

select set_config('request.jwt.claims',
  '{"sub":"44444444-4444-4444-8444-444444444444","role":"authenticated"}', true);
set local role authenticated;

select throws_ok(
  $$select public.cancel_filming_request('f0000000-0000-4000-8000-000000000011')$$,
  '42501', null, 'someone who is not a party cannot cancel');

reset role;

select set_config('request.jwt.claims',
  '{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}', true);
set local role authenticated;

select lives_ok(
  $$select public.cancel_filming_request('f0000000-0000-4000-8000-000000000011')$$,
  'a skater can cancel in good time');
select throws_ok(
  $$select public.cancel_filming_request('f0000000-0000-4000-8000-000000000011')$$,
  '22023', null, 'a cancelled request cannot be cancelled again');

select lives_ok(
  $$select public.cancel_filming_request('f0000000-0000-4000-8000-000000000010')$$,
  'a skater can cancel late');

select lives_ok(
  $$select public.cancel_filming_request('f0000000-0000-4000-8000-000000000005')$$,
  'a skater can cancel a request nobody accepted, even inside 5 hours');

reset role;

select results_eq(
  $$select cancelled_by::text, cancellation_was_late
      from public.filming_requests where id = 'f0000000-0000-4000-8000-000000000011'$$,
  $$values ('skater', false)$$, 'an on-time skater cancellation is recorded as not late');
select is(
  (select count(*)::int from public.payments
    where filming_request_id = 'f0000000-0000-4000-8000-000000000011'),
  0, 'an on-time skater cancellation costs nothing');

select results_eq(
  $$select kind::text, state::text, payer_id, payee_id is null,
           subtotal_cents, fee_cents, fee_basis_points, total_cents, payee_amount_cents
      from public.payments
     where filming_request_id = 'f0000000-0000-4000-8000-000000000010'$$,
  $$values ('late_cancel_fee', 'pending', '11111111-1111-4111-8111-111111111111'::uuid, true,
            0, 1800, 1500, 1800, 0)$$,
  'a late skater cancellation owes 15% of the $120 rate ($18) to Spot Check');

select results_eq(
  $$select cancellation_was_late,
           (select count(*)::int from public.payments
             where filming_request_id = 'f0000000-0000-4000-8000-000000000005')
      from public.filming_requests where id = 'f0000000-0000-4000-8000-000000000005'$$,
  $$values (true, 0)$$,
  'a late cancel of an unaccepted request is recorded as late but has no rate to charge on');

select is(
  (select strike_count from public.filmer_profiles
    where user_id = '22222222-2222-4222-8222-222222222222'),
  3, 'a skater cancelling never gives the filmer a strike');

-- ---------------------------------------------------------------------------
-- Payments: only a late-cancel fee may have Spot Check (null) as the payee
-- ---------------------------------------------------------------------------

select throws_ok(
  $$insert into public.payments
      (kind, payer_id, payee_id, subtotal_cents, fee_cents, fee_basis_points,
       fee_bearer, total_cents, payee_amount_cents)
    values ('filming_session', '11111111-1111-4111-8111-111111111111', null,
            12000, 1800, 1500, 'payer', 13800, 12000)$$,
  '23514', null, 'a filming session payment must have a payee');

select throws_ok(
  $$insert into public.payments
      (kind, payer_id, payee_id, subtotal_cents, fee_cents, fee_basis_points,
       fee_bearer, total_cents, payee_amount_cents)
    values ('late_cancel_fee', '11111111-1111-4111-8111-111111111111',
            '22222222-2222-4222-8222-222222222222',
            0, 1800, 1500, 'payer', 1800, 0)$$,
  '23514', null, 'a late-cancel fee goes to Spot Check, never to a person');

select * from finish();

rollback;
