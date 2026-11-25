// Submits the signed-in user's application to film, records their consent to
// the background check, and -- on QA only -- runs the mock background check.
//
// Backs FilmerQualifyScreen's "Submit for review". The application itself is
// still submit_filmer_application, called AS THE CALLER so auth.uid() is
// theirs and the function's own rules apply (verified adult ID, raw clip).
// This wrapper exists for the two things the client can't do itself:
//
//   * consent_signed_at is deliberately outside the client's column grant, so
//     a signed consent is a server-side record of the request that carried it;
//   * the QA mock, which needs the service role to move review statuses and a
//     background task to do it a minute later.
import { adminClient, callerClient, requireUser, Unauthorized } from '../_shared/supabase.ts';
import { fail, json, preflight } from '../_shared/http.ts';
import {
  mockReviewEnabled,
  parseApplication,
  respondToSubmitError,
  runMockReview,
} from './application.ts';

// Supabase's background-task API. Absent under plain `deno`, hence the guard.
declare const EdgeRuntime: { waitUntil(promise: Promise<unknown>): void } | undefined;

Deno.serve(async (req) => {
  const pre = preflight(req);
  if (pre) return pre;

  try {
    const user = await requireUser(req);
    const authHeader = req.headers.get('Authorization')!;

    const parsed = parseApplication(await req.json().catch(() => null));
    if (!parsed.ok) return json({ error: parsed.error, message: parsed.message }, 400);
    const { application } = parsed;

    const { error: submitError } = await callerClient(authHeader).rpc(
      'submit_filmer_application',
      {
        p_gear: application.gear,
        p_styles: application.styles,
        p_reel_path: application.reelPath,
        p_raw_clip_path: application.rawClipPath,
      },
    );
    if (submitError) {
      const { status, body } = respondToSubmitError(submitError);
      if (status === 500) console.error('submit_filmer_application failed', submitError);
      return json(body, status);
    }

    const db = adminClient();

    // The first consent is the one kept: re-submitting a portfolio doesn't
    // re-sign anything, and the original timestamp is what a check relied on.
    const { error: consentError } = await db
      .from('filmer_profiles')
      .update({ consent_signed_at: new Date().toISOString() })
      .eq('user_id', user.id)
      .is('consent_signed_at', null);
    if (consentError) throw consentError;

    const mocked = mockReviewEnabled((key) => Deno.env.get(key));
    if (mocked && typeof EdgeRuntime !== 'undefined') {
      EdgeRuntime.waitUntil(runMockReview(user.id, {
        wait: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
        passReview: async (userId) => {
          // Only statuses still waiting on review move; a 'failed' set by a
          // person is never overwritten by the mock.
          const { error: checkError } = await db
            .from('filmer_profiles')
            .update({ background_check_status: 'passed' })
            .eq('user_id', userId)
            .in('background_check_status', ['pending', 'in_review']);
          if (checkError) throw checkError;

          const { error: gearError } = await db
            .from('filmer_profiles')
            .update({ gear_review_status: 'passed' })
            .eq('user_id', userId)
            .in('gear_review_status', ['pending', 'in_review']);
          if (gearError) throw gearError;
        },
      }));
    }

    return json({
      status: 'in_review',
      // Lets the app say "about a minute" on QA instead of an open-ended wait.
      mock_review_after_seconds: mocked ? 60 : null,
    });
  } catch (error) {
    if (error instanceof Unauthorized) return fail(error, 401, 'Not signed in.');
    return fail(error, 500, 'Could not submit your application.');
  }
});
