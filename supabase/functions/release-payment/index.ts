// The filmer delivers the clip, and that is what pays them.
//
// Alex, 2026-11-24: "If the filmer sends the clip, they should get paid." So
// this is called by the PAYEE, and delivery is the release trigger --
// matching ClipUploadScreen.swift:66, which promised the filmer exactly that
// ("Delivering releases your payment from escrow").
//
// An earlier revision had the payer call this to confirm receipt. That was
// reversed because it let a skater leave a filmer unpaid indefinitely by
// doing nothing; 20261124120008 records the correction. One consequence worth
// knowing: there is no auto-release timeout anywhere in this system, and none
// is needed, because nothing waits on the skater.
//
// Separate charges and transfers, as 20261124120002 lays out: the charge
// already landed in the PLATFORM balance, and this moves the payee's share on
// to their connected account. `source_transaction` ties the transfer to that
// specific charge rather than requiring an available platform balance.
//
// The amount is `payee_amount_cents` -- never `total_cents`, never recomputed.
// The fee model already decided who bears the fee and
// `payments_fee_model_consistent` holds the row to it: filming adds 15% on top
// so the filmer keeps 100% of their rate, while a pro request takes 20% out.
import { stripe } from '../_shared/stripe.ts';
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

    // Read as the caller, so RLS does the first half of the authorization: a
    // payment between two other people is simply not found.
    const { data: payment, error: readError } = await callerClient(authHeader)
      .from('payments')
      .select(
        'id, state, payer_id, payee_id, payee_amount_cents, currency, stripe_charge_id, delivered_at',
      )
      .eq('id', paymentId)
      .maybeSingle();
    if (readError) throw readError;
    if (!payment) return json({ error: 'No such payment.' }, 404);

    // The person being paid is the one who delivers. The payer must not be
    // able to call this: it would let a skater mark a session delivered that
    // the filmer never shot, and pay them for it.
    if (payment.payee_id !== user.id) {
      return json({ error: 'Only the filmer can deliver.' }, 403);
    }
    if (payment.state !== 'held') {
      return json({ error: `This payment is ${payment.state}, not held.` }, 409);
    }
    if (!payment.stripe_charge_id) {
      // `held` with no charge id should be impossible -- the webhook writes
      // both together -- so this is a bug signal, not a user error.
      throw new Error(`payment ${payment.id} is held with no stripe_charge_id`);
    }

    // Deliberately NOT checked: payer_confirmed_session_at. Gating payment on
    // the skater confirming would rebuild the stall this rule exists to
    // remove. See the note in 20261124120008.

    const { data: payout, error: payoutError } = await db
      .from('payout_accounts')
      .select('stripe_connected_account_id, payouts_enabled')
      .eq('user_id', payment.payee_id)
      .maybeSingle();
    if (payoutError) throw payoutError;

    if (!payout?.stripe_connected_account_id || !payout.payouts_enabled) {
      // The filmer cannot be paid until Stripe will take the money. Nothing is
      // recorded as delivered either, so the clip is not handed over for free:
      // connect-onboarding walks them through finishing setup, then they
      // deliver again.
      return json({
        error: 'payouts_not_ready',
        message: 'Finish setting up payouts before delivering, so this can be paid out.',
      }, 409);
    }

    const transfer = await stripe.transfers.create({
      amount: payment.payee_amount_cents,
      currency: payment.currency,
      destination: payout.stripe_connected_account_id,
      source_transaction: payment.stripe_charge_id,
      transfer_group: payment.id,
      metadata: { payment_id: payment.id, payee_id: payment.payee_id },
    }, {
      // One transfer per payment, ever. Without this, a double tap on
      // "Deliver" pays the filmer twice out of the platform's own money.
      idempotencyKey: `tr_${payment.id}`,
    });

    // Stamp the delivery only once the money has actually moved. The order is
    // the opposite of the previous revision's on purpose: there, the payer's
    // confirmation was worth keeping even if the transfer failed, because a
    // human had tapped something. Here, `delivered_at` is what asserts the
    // filmer was paid for delivering, so recording it against a failed
    // transfer would state something untrue.
    const { error: deliveredError } = await db.rpc('mark_payment_delivered', {
      p_payment_id: payment.id,
    });
    if (deliveredError) throw deliveredError;

    // Moves the row to `released` and appends the timeline entry in one step.
    const { error: eventError } = await db.rpc('record_payment_event', {
      p_payment_id: payment.id,
      p_state: 'released',
      p_note: 'Released to filmer on delivery',
    });
    if (eventError) throw eventError;

    // `arrives_at` is left null on purpose: when the money reaches the
    // filmer's *bank* is a Stripe payout, a later and separate event from this
    // transfer, so filling it in now would be a guess shown as a date.
    const { data: payoutRow, error: payoutInsertError } = await db
      .from('payouts')
      .insert({
        payee_id: payment.payee_id,
        amount_cents: payment.payee_amount_cents,
        currency: payment.currency,
        state: 'released',
        stripe_transfer_id: transfer.id,
      })
      .select('id')
      .single();
    if (payoutInsertError) throw payoutInsertError;

    const { error: itemError } = await db
      .from('payout_items')
      .insert({ payout_id: payoutRow.id, payment_id: payment.id });
    if (itemError) throw itemError;

    return json({
      state: 'released',
      transfer_id: transfer.id,
      amount_cents: payment.payee_amount_cents,
      currency: payment.currency,
    });
  } catch (error) {
    if (error instanceof Unauthorized) return fail(error, 401, 'Not signed in.');
    return fail(error, 500, 'Could not deliver and release this payment.');
  }
});
