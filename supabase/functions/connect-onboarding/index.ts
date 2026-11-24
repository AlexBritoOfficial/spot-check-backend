// Creates or refreshes a Stripe Connect **Express** onboarding link.
//
// Express means Stripe hosts the KYC, bank-details and tax screens. That is a
// deliberate choice and it is why the canvas has no artboards for any of them:
// Payouts.dc.html says "managed with Stripe" and "collected by Stripe for
// payouts", which is a description of a Stripe-hosted flow. The app's job is
// to open the returned URL and, on return, read state back out of
// payout_accounts -- never to collect a bank number itself.
//
// AccountLinks are single-use and expire in minutes, so this is called every
// time the filmer taps through, not once at signup.
import { stripe } from '../_shared/stripe.ts';
import { adminClient, requireUser, Unauthorized } from '../_shared/supabase.ts';
import { fail, json, preflight } from '../_shared/http.ts';

// Where Stripe sends the filmer back to. Universal links into the app; set as
// a function secret so test and production can differ.
const returnBase = () =>
  Deno.env.get('CONNECT_RETURN_URL_BASE') ?? 'https://spot-check-5o1v.vercel.app/connect';

Deno.serve(async (req) => {
  const pre = preflight(req);
  if (pre) return pre;

  try {
    const user = await requireUser(req);
    const db = adminClient();

    // Only someone who can actually earn needs a payout account. has_capability
    // is the same helper RLS uses, so this cannot drift from the drawer gating.
    const { data: canEarn, error: capabilityError } = await db.rpc('has_capability', {
      p_user_id: user.id,
      p_capability: 'filmer',
    });
    if (capabilityError) throw capabilityError;

    const { data: isPro, error: proError } = await db.rpc('has_capability', {
      p_user_id: user.id,
      p_capability: 'pro_skater',
    });
    if (proError) throw proError;

    if (!canEarn && !isPro) {
      return json({ error: 'Only verified filmers and pros can set up payouts.' }, 403);
    }

    const { data: existing, error: readError } = await db
      .from('payout_accounts')
      .select('stripe_connected_account_id, details_submitted, charges_enabled, payouts_enabled')
      .eq('user_id', user.id)
      .maybeSingle();
    if (readError) throw readError;

    let accountId = existing?.stripe_connected_account_id;

    if (!accountId) {
      const account = await stripe.accounts.create({
        // The legacy shorthand for the Express controller settings (Stripe
        // collects requirements, Stripe-hosted Express dashboard, platform
        // pays fees). Still supported in 2026-11-18.endive; the long form is
        // `controller: { requirement_collection: 'stripe', stripe_dashboard:
        // { type: 'express' } }` if this ever needs tuning per-field.
        type: 'express',
        email: user.email,
        capabilities: {
          // transfers only -- the platform takes the card payment itself and
          // transfers on, so the connected account never creates charges.
          transfers: { requested: true },
        },
        // business_type deliberately not set: the Express flow asks the
        // filmer, and guessing 'individual' here would pre-fill the wrong
        // answer for anyone operating as a company.
        metadata: { user_id: user.id },
      }, {
        idempotencyKey: `acct_${user.id}`,
      });
      accountId = account.id;

      // Insert now, before the link is handed out: if the filmer abandons the
      // hosted flow we must still know the account exists, or the next call
      // creates a second one.
      const { error: writeError } = await db
        .from('payout_accounts')
        .insert({ user_id: user.id, stripe_connected_account_id: accountId });
      if (writeError) throw writeError;
    }

    const link = await stripe.accountLinks.create({
      account: accountId,
      // Stripe hits refresh_url when the link has expired -- the app calls
      // this function again from there rather than showing an error.
      refresh_url: `${returnBase()}/refresh`,
      return_url: `${returnBase()}/return`,
      type: 'account_onboarding',
    });

    return json({
      url: link.url,
      expires_at: link.expires_at,
      account_id: accountId,
      // So the app can show Payouts' "Verified" / "Complete" rows without a
      // second round trip. Authoritative values arrive via the webhook.
      details_submitted: existing?.details_submitted ?? false,
      charges_enabled: existing?.charges_enabled ?? false,
      payouts_enabled: existing?.payouts_enabled ?? false,
    });
  } catch (error) {
    if (error instanceof Unauthorized) return fail(error, 401, 'Not signed in.');
    return fail(error, 500, 'Could not start payout setup.');
  }
});
