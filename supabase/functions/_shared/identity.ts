// The decisions identity-session and stripe-webhook make about a user's ID
// check, free of Stripe and Supabase so they can be tested (identity_test.ts).
import { isAdult, type StripeDob } from './age.ts';

/** The part of an identity_verifications row these decisions read. */
export interface IdentityVerificationRow {
  status: 'requires_input' | 'processing' | 'verified' | 'canceled';
  verified_is_adult: boolean | null;
}

/**
 * The slice of `stripe.identity.verificationSessions.retrieve` used here, so
 * a test can stand in for Stripe.
 */
export type VerificationSessionRetrieve = (
  id: string,
  params: { expand: string[] },
  options: { apiKey: string },
) => Promise<{ verified_outputs?: { dob?: StripeDob | null } | null }>;

/**
 * Whether a verified session's document shows someone 18 or older; `null`
 * when Stripe returned no usable date of birth.
 *
 * The date of birth is a *sensitive* verification result. Stripe leaves it out
 * of `expand: ['verified_outputs']`, returns it only when `verified_outputs.dob`
 * is expanded by name, and only to a restricted key with the "Identity
 * Verification Results" and "Recent Detailed Verification Results" read
 * permissions -- the standard secret key is refused. It is also only
 * retrievable for 48 hours after the verification, which is why this runs in
 * the webhook rather than later.
 *
 * The date itself is turned into a boolean here and dropped: IDVerifyScreen
 * promises Spot Check keeps no more than "your verified status and age".
 */
export async function retrieveVerifiedIsAdult(
  retrieve: VerificationSessionRetrieve,
  sessionId: string,
  identityResultsKey: string,
  now: Date = new Date(),
): Promise<boolean | null> {
  const session = await retrieve(
    sessionId,
    { expand: ['verified_outputs.dob'] },
    { apiKey: identityResultsKey },
  );
  return isAdult(session.verified_outputs?.dob, now);
}

/**
 * What "Start verification" does for a user, given their stored row:
 * - `verified`: a final answer, adult or not. A minor retrying cannot change
 *   the date of birth on their ID.
 * - `processing`: Stripe is still checking; the existing session stands.
 * - `create`: start a new session. Includes a verification whose age came back
 *   unknown (no legible date of birth), so that user can prove they are 18+.
 */
export function identitySessionStep(
  existing: IdentityVerificationRow | null,
): 'verified' | 'processing' | 'create' {
  if (existing?.status === 'verified' && existing.verified_is_adult !== null) return 'verified';
  if (existing?.status === 'processing') return 'processing';
  return 'create';
}
