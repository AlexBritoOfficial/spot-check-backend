// What identity-session and stripe-webhook decide about a user's ID check,
// kept out of the handlers so it can be tested without Stripe. Run with:
//
//   docker run --rm -v "$PWD":/fn -w /fn --entrypoint deno \
//     denoland/deno:latest test _shared/identity_test.ts
import { assertEquals } from 'jsr:@std/assert@1';
import {
  identitySessionStep,
  type IdentityVerificationRow,
  retrieveVerifiedIsAdult,
  type VerificationSessionRetrieve,
} from './identity.ts';

const now = new Date(Date.UTC(2026, 10, 26)); // 2026-11-26

/** Records what the webhook asked Stripe for, and answers with `dob`. */
function fakeRetrieve(dob: unknown) {
  const calls: { id: string; params: unknown; options: unknown }[] = [];
  const retrieve: VerificationSessionRetrieve = (id, params, options) => {
    calls.push({ id, params, options });
    return Promise.resolve({ verified_outputs: dob === undefined ? {} : { dob } });
  };
  return { retrieve, calls };
}

// --- retrieveVerifiedIsAdult ------------------------------------------------

Deno.test('asks Stripe for the date of birth by name, with the results key', async () => {
  // Expanding `verified_outputs` alone leaves dob out: it is a sensitive
  // result, returned only when expanded explicitly and only to a restricted
  // key. Missing either one saved verified_is_adult = null for every user.
  const { retrieve, calls } = fakeRetrieve({ year: 1993, month: 4, day: 12 });

  await retrieveVerifiedIsAdult(retrieve, 'vs_1', 'rk_test_results', now);

  assertEquals(calls, [{
    id: 'vs_1',
    params: { expand: ['verified_outputs.dob'] },
    options: { apiKey: 'rk_test_results' },
  }]);
});

Deno.test('an adult date of birth is an adult', async () => {
  const { retrieve } = fakeRetrieve({ year: 1993, month: 4, day: 12 });
  assertEquals(await retrieveVerifiedIsAdult(retrieve, 'vs_1', 'rk', now), true);
});

Deno.test('a minor date of birth is not an adult', async () => {
  const { retrieve } = fakeRetrieve({ year: 2015, month: 1, day: 1 });
  assertEquals(await retrieveVerifiedIsAdult(retrieve, 'vs_1', 'rk', now), false);
});

Deno.test('no date of birth back from Stripe is unknown, not a minor', async () => {
  const { retrieve } = fakeRetrieve(undefined);
  assertEquals(await retrieveVerifiedIsAdult(retrieve, 'vs_1', 'rk', now), null);
});

// --- identitySessionStep -----------------------------------------------------

type Status = IdentityVerificationRow['status'];

const row = (
  status: Status,
  verified_is_adult: boolean | null = null,
): IdentityVerificationRow => ({
  stripe_verification_session_id: 'vs_existing',
  status,
  verified_is_adult,
});

/** Stands in for asking Stripe a session's status; records who was asked. */
function fakeStripeStatus(status: Status) {
  const asked: string[] = [];
  const lookup = (id: string) => {
    asked.push(id);
    return Promise.resolve(status);
  };
  return { lookup, asked };
}

/** For cases that must be decided from the row alone. */
const neverAsked = () => Promise.reject(new Error('Stripe should not be asked'));

Deno.test('no row yet starts a session', async () => {
  assertEquals(await identitySessionStep(null, neverAsked), 'create');
});

Deno.test('a verified adult is done', async () => {
  assertEquals(await identitySessionStep(row('verified', true), neverAsked), 'verified');
});

Deno.test('a verified minor is done: retrying cannot change their date of birth', async () => {
  assertEquals(await identitySessionStep(row('verified', false), neverAsked), 'verified');
});

Deno.test('verified with an unknown age can try again', async () => {
  // Stripe verified the document but returned no legible date of birth, so
  // nobody knows whether they are 18+. Answering "verified" would leave them
  // stuck with no way to prove it.
  assertEquals(await identitySessionStep(row('verified', null), neverAsked), 'create');
});

Deno.test('a session Stripe is still checking is not replaced', async () => {
  assertEquals(await identitySessionStep(row('processing'), neverAsked), 'processing');
});

Deno.test('an abandoned session starts a new one', async () => {
  assertEquals(await identitySessionStep(row('canceled'), neverAsked), 'create');
});

Deno.test('a requires_input row is checked with Stripe before it is replaced', async () => {
  // The row only moves on when a webhook lands. If the user submitted and the
  // webhook is late (or lost), the row still says requires_input -- replacing
  // the session then throws away a verification Stripe already made.
  const { lookup, asked } = fakeStripeStatus('requires_input');
  assertEquals(await identitySessionStep(row('requires_input'), lookup), 'create');
  assertEquals(asked, ['vs_existing']);
});

Deno.test('a submitted session the webhook has not reported yet is kept', async () => {
  const { lookup } = fakeStripeStatus('processing');
  assertEquals(await identitySessionStep(row('requires_input'), lookup), 'processing');
});

Deno.test('a session Stripe verified before the webhook landed is kept', async () => {
  // Answered as processing: the row is only ever made "verified" by the
  // webhook, which is also what works out whether the user is 18+.
  const { lookup } = fakeStripeStatus('verified');
  assertEquals(await identitySessionStep(row('requires_input'), lookup), 'processing');
});

Deno.test('a session Stripe turned down or cancelled starts a new one', async () => {
  assertEquals(
    await identitySessionStep(row('requires_input'), fakeStripeStatus('canceled').lookup),
    'create',
  );
});
