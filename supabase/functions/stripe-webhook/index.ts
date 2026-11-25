// The only writer of identity and payment state.
//
// Everything money- or identity-related in this schema has a SELECT policy and
// no write policy, so the service role used here is the single path by which
// any of it changes. That is the design: a client that could set
// `state = 'held'` could confirm a booking that was never paid for, and a
// client that could set `identity_is_adult` could wave away the 18+ check.
//
// Three things about this file are load-bearing and easy to get wrong:
//
//   1. `constructEventAsync`, never `constructEvent`. The sync version wants
//      Node's crypto and, as of stripe-node 23.x, throws an error telling you
//      so. Signature verification is the only thing standing between this
//      endpoint and anyone on the internet posting a `payment_intent.succeeded`.
//   2. The RAW body. `await req.text()` before anything else -- parsing and
//      re-stringifying changes the bytes and every signature then fails.
//   3. verify_jwt = false for this function (see config.toml). Stripe does not
//      send a Supabase JWT. The signature *is* the authentication.
import { cryptoProvider, stripe, stripeWebhookSecrets } from '../_shared/stripe.ts';
import { adminClient } from '../_shared/supabase.ts';
import { isAdult } from '../_shared/age.ts';

// Maps Stripe's PaymentIntent lifecycle onto our payment_state. 'held' rather
// than 'paid' on success: the money is in the platform balance awaiting the
// transfer to the filmer, which is what Checkout's "WHEN YOU'RE CHARGED"
// describes.
const INTENT_STATE: Record<string, { state: string; note: string }> = {
  'payment_intent.processing': { state: 'processing', note: 'Payment processing' },
  'payment_intent.succeeded': { state: 'held', note: 'Charged and held by Spot Check' },
  'payment_intent.payment_failed': { state: 'declined', note: 'Payment declined' },
  'payment_intent.canceled': { state: 'cancelled', note: 'Payment cancelled' },
};

Deno.serve(async (req) => {
  // Raw text first. See note 2 above.
  const payload = await req.text();
  const signature = req.headers.get('Stripe-Signature');
  if (!signature) return new Response('missing signature', { status: 400 });

  // Tried against each configured destination's secret. The platform and
  // Connect destinations sign with different secrets, and nothing in the
  // request says which one sent it, so the only way to tell is to try.
  let event;
  let lastError: unknown;
  for (const secret of stripeWebhookSecrets()) {
    try {
      event = await stripe.webhooks.constructEventAsync(
        payload,
        signature,
        secret,
        undefined,
        cryptoProvider,
      );
      break;
    } catch (error) {
      lastError = error;
    }
  }

  if (!event) {
    // 400, not 500: a bad signature is not a server fault and Stripe should
    // not retry it. If this fires for account.updated only, the likely cause
    // is a missing STRIPE_WEBHOOK_SECRET_CONNECT, not a broken signature.
    console.error('signature verification failed against all configured secrets', lastError);
    return new Response('invalid signature', { status: 400 });
  }

  const db = adminClient();

  // Idempotency. Stripe redelivers until it gets a 2xx and may redeliver even
  // after one, so the insert is the lock: a duplicate hits the primary key and
  // we return 200 without touching anything. Without this, a redelivered
  // success appends a second "Charged and held" row to the TransactionDetail
  // timeline.
  const { error: seenError } = await db
    .from('stripe_webhook_events')
    .insert({ id: event.id, type: event.type });
  if (seenError) {
    // 23505 is unique_violation: we have already processed this event.
    if (seenError.code === '23505') {
      return new Response(JSON.stringify({ received: true, duplicate: true }), { status: 200 });
    }
    console.error('could not record event id', seenError);
    return new Response('could not record event', { status: 500 });
  }

  try {
    switch (event.type) {
      // --- Identity ------------------------------------------------------
      case 'identity.verification_session.verified': {
        const session = event.data.object;

        // verified_outputs is not included on the event payload -- it has to
        // be expanded on a fresh retrieve. This is the only place the date of
        // birth is ever seen, and it is turned into a boolean on the next line
        // and then dropped: IDVerifyScreen promises Spot Check keeps no more
        // than "your verified status and age".
        const full = await stripe.identity.verificationSessions.retrieve(session.id, {
          expand: ['verified_outputs'],
        });
        const adult = isAdult(full.verified_outputs?.dob);

        const { data: updated, error } = await db
          .from('identity_verifications')
          .update({
            status: 'verified',
            verified_is_adult: adult,
            verified_at: new Date().toISOString(),
            last_error_code: null,
          })
          .eq('stripe_verification_session_id', session.id)
          .select('user_id');
        if (error) throw error;

        // An update that matched nothing would otherwise 200 and throw a real
        // verification away -- the row is created by identity-session, so a
        // miss means this session came from somewhere else (a dashboard test,
        // a session created before a database reset). Logged rather than
        // thrown: retrying cannot create the missing row.
        if (!updated || updated.length === 0) {
          console.warn(`verified session ${session.id} matched no identity_verifications row`);
        }
        // The identity_verifications_mirror trigger copies verified_at and
        // verified_is_adult onto profiles from here. Nothing to do.
        break;
      }

      case 'identity.verification_session.requires_input': {
        const session = event.data.object;
        const { error } = await db
          .from('identity_verifications')
          .update({
            status: 'requires_input',
            // e.g. 'document_expired' -- IDVerifyScreen tells the user why
            // rather than just failing.
            last_error_code: session.last_error?.code ?? null,
          })
          .eq('stripe_verification_session_id', session.id);
        if (error) throw error;
        break;
      }

      case 'identity.verification_session.processing':
      case 'identity.verification_session.canceled': {
        const session = event.data.object;
        const status = event.type.endsWith('processing') ? 'processing' : 'canceled';
        const { error } = await db
          .from('identity_verifications')
          .update({ status })
          .eq('stripe_verification_session_id', session.id);
        if (error) throw error;
        break;
      }

      // --- Payments ------------------------------------------------------
      case 'payment_intent.processing':
      case 'payment_intent.succeeded':
      case 'payment_intent.payment_failed':
      case 'payment_intent.canceled': {
        const intent = event.data.object;
        const mapped = INTENT_STATE[event.type];

        // metadata.payment_id is set by the payment-intent function. Falling
        // back to a lookup by intent id covers anything created outside it
        // (a dashboard test, say) without inventing a row.
        let paymentId = intent.metadata?.payment_id ?? null;
        if (!paymentId) {
          const { data, error } = await db
            .from('payments')
            .select('id')
            .eq('stripe_payment_intent_id', intent.id)
            .maybeSingle();
          if (error) throw error;
          paymentId = data?.id ?? null;
        }
        if (!paymentId) {
          console.warn(`no payments row for ${intent.id}; ignoring ${event.type}`);
          break;
        }

        // On success, record what the card was so TransactionDetail can show
        // "Visa •••• 4242". A display string only -- there is deliberately no
        // column in this schema that could hold a PAN.
        if (event.type === 'payment_intent.succeeded') {
          const charge = typeof intent.latest_charge === 'string'
            ? await stripe.charges.retrieve(intent.latest_charge)
            : intent.latest_charge ?? null;
          const card = charge?.payment_method_details?.card;
          const label = card?.brand && card?.last4
            ? `${card.brand.charAt(0).toUpperCase()}${card.brand.slice(1)} •••• ${card.last4}`
            : null;

          const { error } = await db
            .from('payments')
            .update({ stripe_charge_id: charge?.id ?? null, payment_method_label: label })
            .eq('id', paymentId);
          if (error) throw error;
        }

        // record_payment_event moves the row and appends the timeline entry in
        // one step, so the ledger can never drift from what renders it. It is
        // revoked from every role but service_role.
        const { error: eventError } = await db.rpc('record_payment_event', {
          p_payment_id: paymentId,
          p_state: mapped.state,
          p_note: mapped.note,
        });
        if (eventError) throw eventError;
        break;
      }

      case 'charge.refunded': {
        const charge = event.data.object;
        const { data, error } = await db
          .from('payments')
          .select('id')
          .eq('stripe_charge_id', charge.id)
          .maybeSingle();
        if (error) throw error;
        if (!data) {
          console.warn(`no payments row for charge ${charge.id}`);
          break;
        }
        const { error: eventError } = await db.rpc('record_payment_event', {
          p_payment_id: data.id,
          p_state: 'refunded',
          p_note: 'Refunded',
        });
        if (eventError) throw eventError;
        break;
      }

      // --- Connect -------------------------------------------------------
      case 'account.updated': {
        const account = event.data.object;

        // Stripe's state, reflected -- never ours to decide. payouts_enabled
        // is what Payouts' "Verified" row means.
        const bank = account.external_accounts?.data?.find((a) => a.object === 'bank_account');

        const patch: Record<string, unknown> = {
          charges_enabled: account.charges_enabled ?? false,
          payouts_enabled: account.payouts_enabled ?? false,
          details_submitted: account.details_submitted ?? false,
        };
        if (bank && 'last4' in bank && bank.last4) patch.bank_last4 = bank.last4;

        // Stamped once, on the first event that shows onboarding finished.
        // account.updated fires for all sorts of later changes, so writing
        // these unconditionally would keep moving "Verified" forward to the
        // most recent edit rather than recording when it happened.
        if (account.details_submitted && account.payouts_enabled) {
          const { data: current, error: currentError } = await db
            .from('payout_accounts')
            .select('onboarding_completed_at, verified_at')
            .eq('stripe_connected_account_id', account.id)
            .maybeSingle();
          if (currentError) throw currentError;

          const now = new Date().toISOString();
          if (!current?.onboarding_completed_at) patch.onboarding_completed_at = now;
          if (!current?.verified_at) patch.verified_at = now;
        }
        // tax_details_complete is left alone on purpose: Stripe reports tax
        // collection inside `requirements`, which is a list of field names
        // rather than a flag, and guessing at it would put a wrong "Complete"
        // on the Payouts screen. It needs its own pass.

        const { error } = await db
          .from('payout_accounts')
          .update(patch)
          .eq('stripe_connected_account_id', account.id);
        if (error) throw error;
        break;
      }

      // --- Saved cards ---------------------------------------------------
      case 'payment_method.attached': {
        const pm = event.data.object;
        const customerId = typeof pm.customer === 'string' ? pm.customer : pm.customer?.id;
        if (!customerId) break;

        const { data: profile, error: profileError } = await db
          .from('profiles')
          .select('id')
          .eq('stripe_customer_id', customerId)
          .maybeSingle();
        if (profileError) throw profileError;
        if (!profile) {
          console.warn(`no profile for customer ${customerId}`);
          break;
        }

        const { error } = await db
          .from('payment_methods')
          .upsert({
            user_id: profile.id,
            stripe_payment_method_id: pm.id,
            brand: pm.card?.brand ?? null,
            last4: pm.card?.last4 ?? null,
            exp_month: pm.card?.exp_month ?? null,
            exp_year: pm.card?.exp_year ?? null,
            wallet: pm.card?.wallet?.type ?? null,
          }, { onConflict: 'stripe_payment_method_id' });
        if (error) throw error;
        break;
      }

      case 'payment_method.detached': {
        const pm = event.data.object;
        const { error } = await db
          .from('payment_methods')
          .delete()
          .eq('stripe_payment_method_id', pm.id);
        if (error) throw error;
        break;
      }

      default:
        // Not an error. Stripe sends whatever the endpoint is subscribed to,
        // and an unhandled type must still 200 or Stripe retries it forever.
        console.log(`unhandled event type ${event.type}`);
    }
  } catch (error) {
    // 500 so Stripe retries. The event id row is rolled back by hand first,
    // otherwise the idempotency guard would swallow every retry of an event
    // that failed halfway.
    console.error(`handler failed for ${event.type} (${event.id})`, error);
    await db.from('stripe_webhook_events').delete().eq('id', event.id);
    return new Response('handler failed', { status: 500 });
  }

  return new Response(JSON.stringify({ received: true }), {
    status: 200,
    headers: { 'Content-Type': 'application/json' },
  });
});
