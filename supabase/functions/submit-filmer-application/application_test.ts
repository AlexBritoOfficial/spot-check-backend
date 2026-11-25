// The filmer application's request handling, minus the network. Run with:
//
//   docker run --rm -v "$PWD":/fn -w /fn --entrypoint deno \
//     denoland/deno:latest test submit-filmer-application/application_test.ts
import { assertEquals } from 'jsr:@std/assert@1';
import {
  MOCK_REVIEW_DELAY_MS,
  mockReviewEnabled,
  parseApplication,
  respondToSubmitError,
  runMockReview,
} from './application.ts';

// --- The request body -------------------------------------------------------

const valid = {
  gear: ['VX1000 / tapeless', 'External shotgun mic'],
  styles: ['Street follow-lines'],
  reel_path: null,
  raw_clip_path: 'abc/raw.mov',
  consent: true,
};

Deno.test('a complete application parses', () => {
  assertEquals(parseApplication(valid), {
    ok: true,
    application: {
      gear: ['VX1000 / tapeless', 'External shotgun mic'],
      styles: ['Street follow-lines'],
      reelPath: null,
      rawClipPath: 'abc/raw.mov',
    },
  });
});

Deno.test('the background check needs explicit consent', () => {
  // Not just absent: false, a string "true", anything but the boolean true.
  for (const consent of [undefined, false, 'true', 1]) {
    assertEquals(parseApplication({ ...valid, consent }), {
      ok: false,
      error: 'consent_required',
      message: 'Agree to the background check to apply.',
    });
  }
});

Deno.test('gear and styles must be lists of text', () => {
  assertEquals(parseApplication({ ...valid, gear: 'VX1000' }).ok, false);
  assertEquals(parseApplication({ ...valid, styles: [1, 2] }).ok, false);
});

Deno.test('a missing reel is sent as null, not left out', () => {
  // submit_filmer_application has no parameter defaults, so every key is sent.
  const { reel_path: _omitted, ...withoutReel } = valid;
  const parsed = parseApplication(withoutReel);
  assertEquals(parsed.ok && parsed.application.reelPath, null);
});

Deno.test('the raw clip path is passed through for the database to judge', () => {
  // The "required" rule lives in SQL; the function doesn't duplicate it.
  const parsed = parseApplication({ ...valid, raw_clip_path: '' });
  assertEquals(parsed.ok && parsed.application.rawClipPath, '');
});

Deno.test('a body that is not an object is refused', () => {
  assertEquals(parseApplication(null).ok, false);
  assertEquals(parseApplication('apply').ok, false);
});

// --- What the database's refusals become ------------------------------------

Deno.test('no verified ID: a 403 the app can route to the ID step', () => {
  assertEquals(
    respondToSubmitError({ code: '22023', message: 'verify your ID before applying to film' }),
    {
      status: 403,
      body: {
        error: 'identity_verification_required',
        message: 'Verify your ID before applying to film.',
      },
    },
  );
});

Deno.test('under 18: a different code, so the app stops instead of retrying', () => {
  assertEquals(
    respondToSubmitError({
      code: '22023',
      message: 'you must be 18 or older to film for Spot Check',
    }),
    {
      status: 403,
      body: {
        error: 'adult_verification_required',
        message: 'You must be 18 or older to film for Spot Check.',
      },
    },
  );
});

Deno.test('no raw clip: a 422 with a sentence', () => {
  assertEquals(
    respondToSubmitError({ code: '22023', message: 'a raw follow-line clip is required' }),
    {
      status: 422,
      body: { error: 'raw_clip_required', message: 'Add your raw follow-line clip.' },
    },
  );
});

Deno.test('anything else is a 500 that leaks nothing', () => {
  assertEquals(
    respondToSubmitError({ code: '23505', message: 'duplicate key value violates "x_pkey"' }),
    { status: 500, body: { error: 'Could not submit your application.' } },
  );
});

// --- The QA mock background check -------------------------------------------

Deno.test('the mock runs only when the QA secret says exactly "true"', () => {
  assertEquals(
    mockReviewEnabled((k) => (k === 'MOCK_BACKGROUND_CHECK' ? 'true' : undefined)),
    true,
  );
  assertEquals(mockReviewEnabled(() => undefined), false);
  assertEquals(mockReviewEnabled(() => 'false'), false);
  assertEquals(mockReviewEnabled(() => 'TRUE '), false);
});

Deno.test('the mock waits a minute, then passes the applicant', async () => {
  const calls: string[] = [];
  await runMockReview('user-1', {
    wait: (ms) => {
      calls.push(`wait ${ms}`);
      return Promise.resolve();
    },
    passReview: (userId) => {
      calls.push(`pass ${userId}`);
      return Promise.resolve();
    },
  });
  assertEquals(MOCK_REVIEW_DELAY_MS, 60_000);
  assertEquals(calls, ['wait 60000', 'pass user-1']);
});

Deno.test('a failed mock pass is reported, not thrown into the runtime', async () => {
  const logged: unknown[] = [];
  await runMockReview('user-1', {
    wait: () => Promise.resolve(),
    passReview: () => Promise.reject(new Error('db down')),
    log: (...args) => logged.push(args),
  });
  assertEquals(logged.length, 1);
});
