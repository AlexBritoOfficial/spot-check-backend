// Request plumbing shared by the three client-facing functions.
//
// The webhook deliberately does not use any of this: it is called by Stripe,
// not by a browser, so it needs no CORS and must not be given a JSON error
// body that hides a signature failure behind a 200.

export const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

// Never leaks the underlying Stripe or Postgres message to the client: those
// can contain ids and constraint names. The real one goes to the function log.
export function fail(
  error: unknown,
  status = 500,
  clientMessage = 'Something went wrong.',
): Response {
  console.error(error instanceof Error ? error.stack ?? error.message : error);
  return json({ error: clientMessage }, status);
}

// The iOS app sends a preflight for any request with an Authorization header.
export function preflight(req: Request): Response | null {
  return req.method === 'OPTIONS' ? new Response('ok', { headers: corsHeaders }) : null;
}
