// The pure parts of submit-filmer-application, kept apart from the handler so
// they can be tested without a network or a database (application_test.ts).

export type Application = {
  gear: string[];
  styles: string[];
  reelPath: string | null;
  rawClipPath: string;
};

export type Parsed =
  | { ok: true; application: Application }
  | { ok: false; error: string; message: string };

const isTextList = (value: unknown): value is string[] =>
  Array.isArray(value) && value.every((item) => typeof item === 'string');

/**
 * Reads the app's request body. Consent to the background check must be the
 * boolean `true` -- it is recorded as signed, so nothing looser counts.
 *
 * The raw clip's "required" rule is not repeated here: submit_filmer_application
 * owns it, and a second copy could drift.
 */
export function parseApplication(body: unknown): Parsed {
  const invalid = (message: string): Parsed => ({ ok: false, error: 'invalid_request', message });

  if (typeof body !== 'object' || body === null) return invalid('Send the application as JSON.');
  const b = body as Record<string, unknown>;

  if (b.consent !== true) {
    return {
      ok: false,
      error: 'consent_required',
      message: 'Agree to the background check to apply.',
    };
  }
  if (!isTextList(b.gear)) return invalid('Gear must be a list.');
  if (!isTextList(b.styles)) return invalid('Styles must be a list.');
  if (typeof b.raw_clip_path !== 'string') return invalid('Add your raw follow-line clip.');
  if (b.reel_path !== undefined && b.reel_path !== null && typeof b.reel_path !== 'string') {
    return invalid('The reel must be a file path.');
  }

  return {
    ok: true,
    application: {
      gear: b.gear,
      styles: b.styles,
      // submit_filmer_application has no parameter defaults, so a missing
      // reel must still be sent -- as null.
      reelPath: typeof b.reel_path === 'string' ? b.reel_path : null,
      rawClipPath: b.raw_clip_path,
    },
  };
}

/**
 * Turns submit_filmer_application's refusals (all SQLSTATE 22023) into a
 * status, a machine code the app can route on, and a sentence it can show.
 * The SQL message is matched exactly; anything unrecognised is a 500 that
 * reveals nothing, since Postgres messages can name constraints.
 */
export function respondToSubmitError(
  error: { code?: string; message?: string },
): { status: number; body: Record<string, string> } {
  if (error.code === '22023') {
    switch (error.message) {
      case 'verify your ID before applying to film':
        return {
          status: 403,
          body: {
            error: 'identity_verification_required',
            message: 'Verify your ID before applying to film.',
          },
        };
      case 'you must be 18 or older to film for Spot Check':
        return {
          status: 403,
          body: {
            error: 'adult_verification_required',
            message: 'You must be 18 or older to film for Spot Check.',
          },
        };
      case 'a raw follow-line clip is required':
        return {
          status: 422,
          body: { error: 'raw_clip_required', message: 'Add your raw follow-line clip.' },
        };
    }
  }
  return { status: 500, body: { error: 'Could not submit your application.' } };
}

// --- The QA mock background check -------------------------------------------
//
// Alex, 2026-11-25: on QA, "mock a background check by spawning a thread and
// have it run for a min and then it will pass them." There is no screening
// partner yet, and nothing else ever moves an application out of review.
//
// It also passes the gear review: going live needs both, and the QA portfolio
// is dummy data with nothing real to review.

/** How long the mock takes. Well inside the Free plan's 150s wall clock. */
export const MOCK_REVIEW_DELAY_MS = 60_000;

/**
 * On only where the function secret is exactly "true" -- set on QA by hand,
 * never on production. Anything else, including unset, means a person reviews.
 */
export function mockReviewEnabled(env: (key: string) => string | undefined): boolean {
  return env('MOCK_BACKGROUND_CHECK') === 'true';
}

export type MockReviewDeps = {
  wait: (ms: number) => Promise<void>;
  passReview: (userId: string) => Promise<void>;
  log?: (...args: unknown[]) => void;
};

/**
 * Waits, then passes. Never rejects: it runs as a background task after the
 * response has gone, where a throw would only surface as an unhandled
 * rejection in the runtime, so failures are logged instead.
 */
export async function runMockReview(userId: string, deps: MockReviewDeps): Promise<void> {
  try {
    await deps.wait(MOCK_REVIEW_DELAY_MS);
    await deps.passReview(userId);
  } catch (error) {
    (deps.log ?? console.error)('mock background check failed for', userId, error);
  }
}
