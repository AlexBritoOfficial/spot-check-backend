// Creates (or re-fetches) the PaymentIntent for an existing `payments` row and
// returns everything PaymentSheet needs to present itself.
//
// The amounts are NOT taken from the request body. They are read from the
// payments row, which was written with the fee model already applied and is
// protected by the `payments_fee_model_consistent` check constraint. A client
// that could name its own amount could book a $450 session for $1.
//
// Scope note: this charges with automatic capture, so calling it is what moves
// money. Per 20261124120002_payments.sql the charge happens when the *filmer
// accepts*, not when the skater taps "Confirm request" -- so the accept-time,
// off-session variant (save a method at request time, charge it on accept)
// is still to be designed. See the PR description; R2c wires the on-session
// path first.
import { stripe, STRIPE_API_VERSION } from '../_shared/stripe.ts';
import { adminClient, callerClient, requireUser, Unauthorized } from '../_shared/supabase.ts';
import { fail, json, preflight } from '../_shared/http.ts';

Deno.serve(async (req) => {
  const pre = preflight(req);
  if (pre) return pre;

  try {
    const user = await requireUser(req);
    const authHeader = req.headers.get('Authorization')!;
    const db = adminClient();

    const body = await req.json().catch(() => ({}));
    const paymentId: unknown = body?.payment_id;
    if (typeof paymentId !== 'string' || paymentId.length === 0) {
      return json({ error: 'payment_id is required.' }, 400);
    }

    // Read through the CALLER's client on purpose: the "parties read their
    // payments" policy does the authorization, so a payment belonging to two
    // other people is simply not found. Re-checking payer_id below is belt and
    // braces for the case where that policy is ever loosened to payees.
    const { data: payment, error: readError } = await callerClient(authHeader)
      .from('payments')
      .select('id, state, payer_id, total_cents, currency, stripe_payment_intent_id, kind')
      .eq('id', paymentId)
      .maybeSingle();
    if (readError) throw readError;
    if (!payment) return json({ error: 'No such payment.' }, 404);

    if (payment.payer_id !== user.id) {
      return json({ error: 'Only the payer can pay a payment.' }, 403);
    }
    if (payment.state !== 'pending' && payment.state !== 'processing') {
      // Re-paying a released or refunded payment would double-charge.
      return json({ error: `This payment is already ${payment.state}.` }, 409);
    }

    // --- The money-movement gate -------------------------------------------
    // Trust/IDVerifyScreen.swift:19 -- verification is triggered by money
    // moving, not by holding a capability. This is where that rule is actually
    // enforced; the screen only explains it. Read with the admin client
    // because identity columns are deliberately not readable cross-user.
    const { data: profile, error: profileError } = await db
      .from('profiles')
      .select('stripe_customer_id, identity_verified_at, identity_is_adult')
      .eq('id', user.id)
      .single();
    if (profileError) throw profileError;

    if (!profile.identity_verified_at) {
      return json({ error: 'identity_verification_required', requires: 'identity' }, 403);
    }
    if (profile.identity_is_adult !== true) {
      // `profiles.age` is self-reported and may legitimately be 13. It is not
      // a gate and must never be used as one -- this column is the gate.
      return json({ error: 'adult_verification_required', requires: 'adult' }, 403);
    }

    // --- The Customer, created lazily --------------------------------------
    let customerId = profile.stripe_customer_id;
    if (!customerId) {
      const customer = await stripe.customers.create({
        email: user.email,
        metadata: { user_id: user.id },
      });
      customerId = customer.id;

      // Written with the admin client: stripe_customer_id is excluded from the
      // authenticated column GRANT precisely so a client cannot point itself
      // at someone else's saved cards.
      const { error: customerWriteError } = await db
        .from('profiles')
        .update({ stripe_customer_id: customerId })
        .eq('id', user.id);
      if (customerWriteError) throw customerWriteError;
    }

    // --- The PaymentIntent, created once -----------------------------------
    // Reused if this row already has one, so a user who backgrounds the app
    // during checkout and comes back does not create a second charge.
    let intent;
    if (payment.stripe_payment_intent_id) {
      intent = await stripe.paymentIntents.retrieve(payment.stripe_payment_intent_id);
    } else {
      intent = await stripe.paymentIntents.create({
        amount: payment.total_cents,
        currency: payment.currency,
        customer: customerId,
        // Separate charges and transfers: the charge lands in the PLATFORM
        // balance and is transferred to the filmer later, on confirm. Hence no
        // `transfer_data` / `on_behalf_of` here -- adding either would pay the
        // filmer immediately and break the hold the canvas promises.
        automatic_payment_methods: { enabled: true },
        // The webhook's only link back to our row.
        metadata: { payment_id: payment.id, payer_id: user.id, kind: payment.kind },
      }, {
        // Stripe-side idempotency, so a retried request cannot create a second
        // intent even if our own write below fails.
        idempotencyKey: `pi_${payment.id}`,
      });

      const { error: intentWriteError } = await db
        .from('payments')
        .update({ stripe_payment_intent_id: intent.id })
        .eq('id', payment.id);
      if (intentWriteError) throw intentWriteError;
    }

    // PaymentSheet needs an ephemeral key to show and manage saved cards.
    //
    // Gotcha: this apiVersion must be the one the *iOS* SDK expects, which is
    // not always the server's pinned version. If PaymentSheet reports an
    // invalid ephemeral key in R2c, this line is the knob -- not the server
    // pin in _shared/stripe.ts.
    const ephemeralKey = await stripe.ephemeralKeys.create(
      { customer: customerId },
      { apiVersion: STRIPE_API_VERSION },
    );

    return json({
      payment_intent_client_secret: intent.client_secret,
      ephemeral_key_secret: ephemeralKey.secret,
      customer_id: customerId,
      amount_cents: payment.total_cents,
      currency: payment.currency,
    });
  } catch (error) {
    if (error instanceof Unauthorized) return fail(error, 401, 'Not signed in.');
    return fail(error, 500, 'Could not start this payment.');
  }
});
