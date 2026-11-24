// Starts (or resumes) Stripe Identity verification for the calling user.
//
// Backs Trust/IDVerifyScreen's "Start verification" button. The rule that
// screen states -- "Everyone who books, pays or gets paid verifies once" --
// is why this is keyed on the user and not on a payment: one row per person in
// identity_verifications, reused across retries.
//
// This function creates a session and returns its client_secret. It writes the
// *pending* row only. It never writes a verified status -- that is the
// webhook's job, because a client that could report its own verification
// result could simply report success.
import { stripe } from '../_shared/stripe.ts';
import { adminClient, requireUser, Unauthorized } from '../_shared/supabase.ts';
import { fail, json, preflight } from '../_shared/http.ts';

Deno.serve(async (req) => {
  const pre = preflight(req);
  if (pre) return pre;

  try {
    const user = await requireUser(req);
    const db = adminClient();

    // Already verified? Say so instead of charging through another session.
    // IDVerifyScreen can skip straight ahead on this.
    const { data: existing, error: readError } = await db
      .from('identity_verifications')
      .select('stripe_verification_session_id, status')
      .eq('user_id', user.id)
      .maybeSingle();
    if (readError) throw readError;

    if (existing?.status === 'verified') {
      return json({ status: 'verified' });
    }

    // A session that is still answerable is reused rather than replaced, so a
    // user who backgrounds the app mid-flow comes back to the same one.
    if (existing && existing.status === 'processing') {
      return json({ status: 'processing' });
    }

    const session = await stripe.identity.verificationSessions.create({
      type: 'document',
      // Stripe computes adulthood for us and we keep only the boolean. Asking
      // for the DOB check here is what makes verified_outputs.dob populated at
      // webhook time.
      // A selfie match, so a stolen document alone does not verify. Date of
      // birth comes back in verified_outputs from the document itself -- there
      // is no separate DOB check to request.
      options: { document: { require_matching_selfie: true } },
      // The only link back from a webhook to a user. Stripe returns metadata
      // on the event, so the webhook never has to guess or look up by session.
      metadata: { user_id: user.id },
    });

    // Upsert, not insert: a previous `requires_input` or `canceled` attempt
    // reuses the row, which is what the table's one-row-per-user primary key
    // requires. Status resets to the new session's.
    const { error: writeError } = await db
      .from('identity_verifications')
      .upsert({
        user_id: user.id,
        stripe_verification_session_id: session.id,
        status: session.status,
        last_error_code: null,
      }, { onConflict: 'user_id' });
    if (writeError) throw writeError;

    return json({
      status: session.status,
      // StripeIdentity's iOS SDK takes exactly these two.
      client_secret: session.client_secret,
      session_id: session.id,
    });
  } catch (error) {
    if (error instanceof Unauthorized) return fail(error, 401, 'Not signed in.');
    return fail(error, 500, 'Could not start verification.');
  }
});
