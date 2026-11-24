// The skater confirms they received their clips, and the filmer gets paid.
//
// This is the last step of the canvas's escrow trail
// (ClipVaultScreen.swift:55-60): Charged & held -> Both confirmed -> Raw clips
// delivered -> **Filmer paid**. The payer confirming receipt is the trigger
// (Alex, 2026-11-24).
//
// Separate charges and transfers, as 20261124120002 lays out: the charge
// already landed in the PLATFORM balance, and this moves the payee's share on
// to their connected account. `source_transaction` ties the transfer to the
// original charge, so it draws on those specific funds rather than requiring
// an available platform balance.
//
// The amount transferred is `payee_amount_cents` -- never `total_cents` and
// never recomputed here. The fee model already decided who bears the fee, and
// `payments_fee_model_consistent` holds the row to it: for filming the skater
// paid rate + 15% and the filmer keeps 100% of their rate, while for a pro
// request 20% comes out of the price. Recomputing either here would be a
// second source of truth for money.
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

    // Read as the caller, so RLS does the first half of the authorization.
    const { data: payment, error: readError } = await callerClient(authHeader)
      .from('payments')
      .select(
        'id, state, payer_id, payee_id, payee_amount_cents, currency, stripe_charge_id, delivered_at, confirmed_at',
      )
      .eq('id', paymentId)
      .maybeSingle();
    if (readError) throw readError;
    if (!payment) return json({ error: 'No such payment.' }, 404);

    // The payer confirms receipt. The payee must not be able to release their
    // own escrow -- that is the whole point of holding it.
    if (payment.payer_id !== user.id) {
      return json({ error: 'Only the payer can confirm receipt.' }, 403);
    }
    if (payment.state !== 'held') {
      return json({ error: `This payment is ${payment.state}, not held.` }, 409);
    }
    // Cannot confirm receipt of something that was never delivered. Also
    // keeps the escrow trail in order rather than letting step 4 precede 3.
    if (!payment.delivered_at) {
      return json({
        error: 'not_delivered',
        message: 'The filmer has not delivered the clips yet.',
      }, 409);
    }
    if (!payment.stripe_charge_id) {
      // `held` without a charge id should be impossible -- the webhook writes
      // both together -- so this is a bug signal, not a user error.
      throw new Error(`payment ${payment.id} is held with no stripe_charge_id`);
    }

    // The filmer needs somewhere for the money to go. Checked before the
    // transfer so the skater gets a clear answer instead of a Stripe error.
    const { data: payout, error: payoutError } = await db
      .from('payout_accounts')
      .select('stripe_connected_account_id, payouts_enabled')
      .eq('user_id', payment.payee_id)
      .maybeSingle();
    if (payoutError) throw payoutError;

    if (!payout?.stripe_connected_account_id || !payout.payouts_enabled) {
      // Deliberately not a failure of the confirmation: the skater has done
      // their part. The money stays held and the filmer has to finish payout
      // setup, which connect-onboarding walks them through.
      return json({
        error: 'payee_payouts_not_ready',
        message: 'The filmer has not finished setting up payouts yet. Your confirmation is saved.',
      }, 409);
    }

    // Record the confirmation first. If the transfer then fails, the skater's
    // confirmation is not lost and a retry does not ask them to tap again --
    // and because confirmed_at is only ever set here, it cannot be forged.
    if (!payment.confirmed_at) {
      const { error: confirmError } = await db
        .from('payments')
        .update({ confirmed_at: new Date().toISOString() })
        .eq('id', payment.id);
      if (confirmError) throw confirmError;
    }

    const transfer = await stripe.transfers.create({
      amount: payment.payee_amount_cents,
      currency: payment.currency,
      destination: payout.stripe_connected_account_id,
      // Draws on the funds from this specific charge.
      source_transaction: payment.stripe_charge_id,
      transfer_group: payment.id,
      metadata: { payment_id: payment.id, payee_id: payment.payee_id },
    }, {
      // One transfer per payment, ever. Without this, a double tap or a retry
      // after a timeout pays the filmer twice out of the platform's own money.
      idempotencyKey: `tr_${payment.id}`,
    });

    // Moves the row to `released` and appends the timeline entry in one step.
    const { error: eventError } = await db.rpc('record_payment_event', {
      p_payment_id: payment.id,
      p_state: 'released',
      p_note: 'Released to filmer',
    });
    if (eventError) throw eventError;

    // The earning side's record. `arrives_at` is left null on purpose: when
    // the money reaches the filmer's *bank* is a Stripe payout, a later and
    // separate event from this transfer, so filling it in now would be a
    // guess shown to the filmer as a date.
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
    return fail(error, 500, 'Could not release this payment.');
  }
});
