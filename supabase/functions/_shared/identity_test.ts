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

const row = (
  status: IdentityVerificationRow['status'],
  verified_is_adult: boolean | null = null,
): IdentityVerificationRow => ({ status, verified_is_adult });

Deno.test('no row yet starts a session', () => {
  assertEquals(identitySessionStep(null), 'create');
});

Deno.test('a verified adult is done', () => {
  assertEquals(identitySessionStep(row('verified', true)), 'verified');
});

Deno.test('a verified minor is done: retrying cannot change their date of birth', () => {
  assertEquals(identitySessionStep(row('verified', false)), 'verified');
});

Deno.test('verified with an unknown age can try again', () => {
  // Stripe verified the document but returned no legible date of birth, so
  // nobody knows whether they are 18+. Answering "verified" would leave them
  // stuck with no way to prove it.
  assertEquals(identitySessionStep(row('verified', null)), 'create');
});

Deno.test('a session Stripe is still checking is not replaced', () => {
  assertEquals(identitySessionStep(row('processing')), 'processing');
});

Deno.test('a turned-down or abandoned session starts a new one', () => {
  assertEquals(identitySessionStep(row('requires_input')), 'create');
  assertEquals(identitySessionStep(row('canceled')), 'create');
});
