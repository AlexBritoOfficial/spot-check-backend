-- ~8 fabricated Boston-area spots (not exported from spot-check's own
-- database -- that's explicitly out of scope). Ownerless (owner_id null,
-- which is allowed) since no auth test users are created here. Two are
-- private, to exercise RLS's visibility rule and the Bookmarks screen's
-- "your private spots" filter.

insert into public.spots
  (name, city, spot_type, description, features, difficulty, is_skateable, is_public, rating, lat, lng, status)
values
  ('Eggs', 'Boston', 'street', 'Ledges by the water',
    array['ledge', 'stairs']::public.feature[], 'intermediate', true, true, 5, 42.3554, -71.0656, 'active'),

  ('AQ', 'Boston', 'street', 'Marble ledges downtown',
    array['ledge', 'plaza']::public.feature[], 'intermediate', true, false, 0, 42.3600, -71.0530, 'active'),

  ('Copley Library', 'Boston', 'street', 'Awesome flatground and three stairs',
    array['stairs', 'plaza']::public.feature[], 'intermediate', true, true, 4, 42.3493, -71.0767, 'active'),

  ('Lynch Family Skatepark', 'Cambridge', 'park', 'Boston''s all concrete skatepark',
    array['skatepark']::public.feature[], 'advanced', true, true, 5, 42.3730, -71.0760, 'active'),

  ('Harvard Steps', 'Cambridge', 'street', 'Classic gap-to-rail set, security kicks out fast',
    array['rail', 'stairs']::public.feature[], 'advanced', true, false, 0, 42.3770, -71.1167, 'active'),

  ('Christian Science Plaza', 'Boston', 'street', 'Smooth plaza ground, mellow ledges',
    array['plaza', 'ledge']::public.feature[], 'beginner', true, true, 4, 42.3430, -71.0870, 'active'),

  ('Somerville DIY', 'Somerville', 'diy', 'Volunteer-built quarter pipes and a rail',
    array['rail', 'skatepark']::public.feature[], 'pro', true, true, 3, 42.3876, -71.0995, 'pending'),

  ('South Boston Bowl', 'Boston', 'park', 'Beginner-friendly bowl near the water',
    array['skatepark']::public.feature[], 'beginner', true, true, 4, 42.3380, -71.0452, 'active');


-- ---------------------------------------------------------------------------
-- Role fixtures
-- ---------------------------------------------------------------------------
-- Five accounts, one per privilege the app can be in, so the capability
-- gating and mode switcher have something real to switch between. Without
-- these there is nothing to test against -- every account looks identical
-- until a capability row exists.
--
-- All share the password `spotcheck123`. Local fixtures only; this file is
-- never run against a deployed database.

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at,
  confirmation_token, recovery_token, email_change_token_new, email_change
)
select
  '00000000-0000-0000-0000-000000000000',
  u.id,
  'authenticated',
  'authenticated',
  u.email,
  extensions.crypt('spotcheck123', extensions.gen_salt('bf')),
  now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  jsonb_build_object('username', u.username, 'home_city', u.city),
  now(), now(),
  '', '', '', ''
from (values
  ('11111111-1111-4111-8111-111111111111'::uuid, 'skater@spotcheck.test', 'rider_nguyen',  'Boston'),
  ('22222222-2222-4222-8222-222222222222'::uuid, 'filmer@spotcheck.test', 'rider_okafor',  'Boston'),
  ('33333333-3333-4333-8333-333333333333'::uuid, 'paused@spotcheck.test', 'rider_silva',   'Boston'),
  ('44444444-4444-4444-8444-444444444444'::uuid, 'shop@spotcheck.test',   'bricktown',     'Boston'),
  ('55555555-5555-4555-8555-555555555555'::uuid, 'pro@spotcheck.test',    'rider_chen',    'Boston')
) as u(id, email, username, city)
on conflict (id) do nothing;

-- Identity: everyone who gets paid has verified. The plain skater has not --
-- that is the point of them, and it is what IDVerify gates on at first booking.
insert into public.identity_verifications
  (user_id, stripe_verification_session_id, status, verified_is_adult, verified_at)
values
  ('22222222-2222-4222-8222-222222222222', 'vs_test_filmer', 'verified', true, now()),
  ('33333333-3333-4333-8333-333333333333', 'vs_test_paused', 'verified', true, now()),
  ('55555555-5555-4555-8555-555555555555', 'vs_test_pro',    'verified', true, now())
on conflict (user_id) do nothing;

-- A live filmer, and one paused at 3 of 3 strikes (StrikePaused).
insert into public.filmer_profiles (
  user_id, gear, styles, reel_path, raw_clip_path,
  hourly_rate_cents, park_drop_in_cents,
  consent_signed_at, gear_review_status, background_check_status,
  went_live_at, strike_count, paused_at
) values
  ('22222222-2222-4222-8222-222222222222',
   array['VX1000 / tapeless', 'External shotgun mic'],
   array['Street follow-lines', 'Night / external lighting'],
   '22222222-2222-4222-8222-222222222222/reel.mp4',
   '22222222-2222-4222-8222-222222222222/raw.mp4',
   6000, 4000, now(), 'passed', 'passed', now(), 0, null),
  ('33333333-3333-4333-8333-333333333333',
   array['DSLR/mirrorless + fisheye'],
   array['Park / transition'],
   null,
   '33333333-3333-4333-8333-333333333333/raw.mp4',
   5500, null, now(), 'passed', 'passed', now() - interval '60 days', 3, now() - interval '6 days')
on conflict (user_id) do nothing;

-- The shop, and its member. Industry is org-backed, never a flag on a person.
insert into public.organizations (id, kind, name, official_email, verified_at)
values ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'shop',
        'Bricktown Skate Shop', 'crew@bricktown.test', now())
on conflict (id) do nothing;

insert into public.organization_members (organization_id, user_id, title)
values ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        '44444444-4444-4444-8444-444444444444', 'team manager')
on conflict do nothing;

-- An unredeemed invite, so the redemption RPC has something to exercise.
-- Plain code: SPOTCHECK-BRICKTOWN
insert into public.organization_invites (code_hash, organization_id, email, expires_at)
values (public.hash_invite_code('SPOTCHECK-BRICKTOWN'),
        'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'crew@bricktown.test',
        now() + interval '30 days')
on conflict (code_hash) do nothing;

-- Capabilities. The filmer rows deliberately go in as 'active' so the mirror
-- trigger populates profiles.filmer, which is how the old boolean stays
-- truthful without anyone writing to it.
insert into public.profile_capabilities (user_id, capability, status, granted_at)
values
  ('22222222-2222-4222-8222-222222222222', 'filmer',     'active', now()),
  ('33333333-3333-4333-8333-333333333333', 'filmer',     'paused', now() - interval '60 days'),
  ('44444444-4444-4444-8444-444444444444', 'industry',   'active', now()),
  ('55555555-5555-4555-8555-555555555555', 'pro_skater', 'active', now())
on conflict (user_id, capability) do nothing;

-- One payment per state the Transactions screen can render, so its filter
-- chips and the receipt timeline have real rows behind them.
--
-- Filming is payer-borne 15%: 12000 + 1800 = 13800 charged, filmer keeps 12000.
-- Pro is payee-borne 20%:    4000 charged, pro receives 3200.
-- Anything that reached `held` or beyond necessarily has Stripe ids: the
-- webhook writes the intent id and the charge id together with the state, so
-- a held payment without a charge id cannot exist in production. The fixtures
-- used to omit them, which release-payment's own invariant check caught --
-- it refuses to transfer against a held payment with no charge to draw on.
-- `declined` keeps an intent but no charge, because the charge never
-- succeeded, which is exactly the real shape.
insert into public.payments (
  id, kind, state, payer_id, payee_id,
  subtotal_cents, fee_cents, fee_basis_points, fee_bearer,
  total_cents, payee_amount_cents, payment_method_label,
  stripe_payment_intent_id, stripe_charge_id, delivered_at, confirmed_at
) values
  ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1', 'filming_session', 'held',
   '11111111-1111-4111-8111-111111111111', '22222222-2222-4222-8222-222222222222',
   12000, 1800, 1500, 'payer', 13800, 12000, 'Visa •••• 4242',
   'pi_test_held_1', 'ch_test_held_1', null, null),
  ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2', 'pro_request', 'released',
   '11111111-1111-4111-8111-111111111111', '55555555-5555-4555-8555-555555555555',
   4000, 800, 2000, 'payee', 4000, 3200, 'Visa •••• 4242',
   'pi_test_released_2', 'ch_test_released_2',
   now() - interval '3 days', now() - interval '3 days'),
  ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb3', 'filming_session', 'refunded',
   '11111111-1111-4111-8111-111111111111', '33333333-3333-4333-8333-333333333333',
   9000, 1350, 1500, 'payer', 10350, 9000, 'Visa •••• 4242',
   'pi_test_refunded_3', 'ch_test_refunded_3', null, null),
  ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb4', 'filming_session', 'declined',
   '11111111-1111-4111-8111-111111111111', '22222222-2222-4222-8222-222222222222',
   15000, 2250, 1500, 'payer', 17250, 15000, 'Visa •••• 4242',
   'pi_test_declined_4', null, null, null)
on conflict (id) do nothing;

-- The held payment's history, which is what TransactionDetail's STATUS list
-- renders -- it is a record, never recomputed from the current state.
insert into public.payment_events (payment_id, state, note, occurred_at)
values
  ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1', 'pending', 'Requested', now() - interval '5 days'),
  ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1', 'held',
   'Rider Okafor accepted', now() - interval '5 days' + interval '88 minutes')
on conflict do nothing;

-- charges_enabled/details_submitted/onboarding_completed_at arrived with
-- 20261124120006 and default false, which would leave these fixtures saying a
-- filmer can be paid out but never finished onboarding. Both of these are
-- fully onboarded filmers, so all three are set.
insert into public.payout_accounts
  (user_id, stripe_connected_account_id, bank_last4, payouts_enabled,
   tax_details_complete, verified_at, charges_enabled, details_submitted,
   onboarding_completed_at)
values
  ('22222222-2222-4222-8222-222222222222', 'acct_test_filmer', '6789', true,
   true, now(), true, true, now()),
  ('55555555-5555-4555-8555-555555555555', 'acct_test_pro',    '4321', true,
   true, now(), true, true, now())
on conflict (user_id) do nothing;

insert into public.payouts (id, payee_id, amount_cents, state, arrives_at)
values ('cccccccc-cccc-4ccc-8ccc-ccccccccccc1',
        '22222222-2222-4222-8222-222222222222', 12000, 'released',
        now() + interval '2 days')
on conflict (id) do nothing;

insert into public.payout_items (payout_id, payment_id)
values ('cccccccc-cccc-4ccc-8ccc-ccccccccccc1',
        'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2')
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- Filming requests
-- ---------------------------------------------------------------------------
-- One of each thing Discover and the skater's bookings have to draw: an open
-- request any filmer can take, one named for the live filmer, and the accepted
-- session behind the held payment above -- which until now paid for nothing.
-- Times are relative to the reset, so they are always in the future locally.
insert into public.filming_requests (
  id, skater_id, requested_filmer_id, filmer_id, package, spot_id, lat, lng,
  location_label, starts_at, ends_at, lighting, security_risk, notes,
  status, accepted_at, rate_cents
)
values
  ('dddddddd-dddd-4ddd-8ddd-ddddddddddd1', '11111111-1111-4111-8111-111111111111',
   null, null, 'hourly_street', null, 42.3497, -71.0760,
   'Pin near Copley Square',
   date_trunc('day', now()) + interval '2 days 17 hours',
   date_trunc('day', now()) + interval '2 days 19 hours',
   'golden_hour', 'sometimes', 'Kickflip down the three', 'requested', null, null),
  ('dddddddd-dddd-4ddd-8ddd-ddddddddddd2', '11111111-1111-4111-8111-111111111111',
   '22222222-2222-4222-8222-222222222222', null, 'park_drop_in',
   (select id from public.spots where name = 'Lynch Family Skatepark'), 42.3730, -71.0760,
   'Lynch Family Skatepark',
   date_trunc('day', now()) + interval '3 days 14 hours',
   date_trunc('day', now()) + interval '3 days 15 hours',
   'daylight', 'low', null, 'requested', null, null),
  ('dddddddd-dddd-4ddd-8ddd-ddddddddddd3', '11111111-1111-4111-8111-111111111111',
   null, '22222222-2222-4222-8222-222222222222', 'hourly_street',
   (select id from public.spots where name = 'Eggs'), 42.3554, -71.0656,
   'Eggs',
   date_trunc('day', now()) + interval '1 day 17 hours',
   date_trunc('day', now()) + interval '1 day 19 hours',
   'golden_hour', 'sometimes', null, 'accepted', now() - interval '5 days', 12000)
on conflict (id) do nothing;

update public.payments
   set filming_request_id = 'dddddddd-dddd-4ddd-8ddd-ddddddddddd3'
 where id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1';
