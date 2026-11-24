// Two clients, and the difference between them is the whole security model.
//
//   callerClient  carries the end user's JWT, so RLS applies. Used to find out
//                 *who is asking* and to read anything they are allowed to read.
//   adminClient   service role, bypasses RLS. Used only to write money and
//                 identity state, which no policy permits a client to write.
//
// Pinned for reproducible deploys -- unrelated to the Swift SDK's 2.49.0 pin,
// which exists because of this machine's Xcode toolchain and has no bearing
// here. Bump this deliberately, not by floating a caret range.
//
// Mixing these up is the one mistake in this directory that would matter:
// doing an authorization check with adminClient always succeeds.
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2.119.2';

// SUPABASE_URL and the two keys are injected into every deployed function by
// the platform -- they are not secrets this repo sets.
const url = Deno.env.get('SUPABASE_URL')!;
const anonKey = Deno.env.get('SUPABASE_ANON_KEY')!;
const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

export function adminClient(): SupabaseClient {
  return createClient(url, serviceKey, { auth: { persistSession: false } });
}

export function callerClient(authHeader: string): SupabaseClient {
  return createClient(url, anonKey, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false },
  });
}

export class Unauthorized extends Error {}

/**
 * Resolves the calling user from the request's own JWT.
 *
 * `verify_jwt` is on for these functions, so a request without a valid token
 * never reaches the handler -- but that only proves the token is *a* valid
 * token, not whose it is. Everything that follows keys off this id rather than
 * off any id in the request body, which is what stops one user creating a
 * PaymentIntent against another user's payment row.
 */
export async function requireUser(req: Request): Promise<{ id: string; email?: string }> {
  const authHeader = req.headers.get('Authorization');
  if (!authHeader) throw new Unauthorized('missing Authorization header');

  const { data, error } = await callerClient(authHeader).auth.getUser();
  if (error || !data.user) throw new Unauthorized(error?.message ?? 'no user for token');

  return { id: data.user.id, email: data.user.email ?? undefined };
}
