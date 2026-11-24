-- Correction: delivering the clip is what releases the money, not the
-- skater confirming receipt.
--
-- 20261124120007 implemented the opposite and its comments say so. Migrations
-- are forward-only, so this migration corrects the record rather than editing
-- that one. Alex, 2026-11-24: "If the filmer sends the clip, they should get
-- paid" and "The filmer will get paid upon sending the clip."
--
-- This also vindicates ClipUploadScreen.swift:66, which told the filmer
-- "Delivering releases your payment from escrow" all along. That copy stays;
-- the implementation moved to match it.
--
-- Why it matters beyond a trigger swap: paying on delivery removes the stall
-- entirely. Under the previous rule a skater could leave a filmer unpaid
-- forever by never tapping confirm, which is why an auto-release window was
-- needed. There is nothing to wait for now, so no timeout exists and none is
-- needed.

-- ---------------------------------------------------------------------------
-- Step 2 of the escrow trail: both sides confirm the session happened
-- ---------------------------------------------------------------------------

-- ClipVaultScreen.swift:57 draws "Both confirmed" as a real step, and Alex
-- confirmed it carries weight: "if both skaters confirmed the session happened
-- then the uploaded clip from the filmer will hold. 9/10 when the skater lands
-- the trick or doesn't, they will both review the footage."
--
-- So it is recorded per side, by the person it belongs to.
alter table public.payments
  add column payer_confirmed_session_at timestamptz,
  add column payee_confirmed_session_at timestamptz;

comment on column public.payments.payer_confirmed_session_at is
  'When the payer confirmed the session took place. Evidence for disputes; deliberately NOT a gate on delivery.';
comment on column public.payments.payee_confirmed_session_at is
  'When the payee confirmed the session took place. Evidence for disputes; deliberately NOT a gate on delivery.';

-- A JUDGEMENT CALL, flagged rather than buried: these do not block delivery.
-- Gating release on the skater confirming the session would rebuild exactly
-- the stall that paying-on-delivery removes -- the skater would simply withhold
-- this confirmation instead of the receipt one, and the filmer would again be
-- unpaid with no recourse. Alex's rule is imperative ("if the filmer sends the
-- clip, they should get paid") while the both-confirmed step was permissive
-- ("can be used for the escrow"), so the imperative wins and this is evidence,
-- not a lock. Reverse it by adding the check to mark_payment_delivered.

create or replace function public.confirm_session_happened(p_payment_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_payer uuid;
  v_payee uuid;
  v_state public.payment_state;
begin
  select p.payer_id, p.payee_id, p.state
    into v_payer, v_payee, v_state
    from public.payments p
   where p.id = p_payment_id;

  if not found then
    raise exception 'no such payment %', p_payment_id using errcode = '22023';
  end if;

  -- Each side confirms only its own half. Nobody confirms on another's behalf.
  if auth.uid() = v_payer then
    update public.payments
       set payer_confirmed_session_at = coalesce(payer_confirmed_session_at, now())
     where id = p_payment_id;
  elsif auth.uid() = v_payee then
    update public.payments
       set payee_confirmed_session_at = coalesce(payee_confirmed_session_at, now())
     where id = p_payment_id;
  else
    raise exception 'only a party to this payment can confirm the session'
      using errcode = '42501';
  end if;

  -- coalesce above makes a second tap a no-op, so only the first one lands on
  -- the timeline.
  insert into public.payment_events (payment_id, state, note)
  select p_payment_id, v_state,
         case when auth.uid() = v_payer then 'Skater confirmed the session'
              else 'Filmer confirmed the session' end
   where not exists (
     select 1 from public.payment_events e
      where e.payment_id = p_payment_id
        and e.note = case when auth.uid() = v_payer
                          then 'Skater confirmed the session'
                          else 'Filmer confirmed the session' end
   );
end;
$$;

revoke all on function public.confirm_session_happened(uuid) from public, anon;
grant execute on function public.confirm_session_happened(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Correcting what 20261124120007 said
-- ---------------------------------------------------------------------------

-- confirmed_at is no longer the release trigger. It is kept, not dropped: the
-- skater acknowledging receipt in ClipVault is still a real thing the canvas
-- draws, and it is useful evidence if a filmer's delivery is later disputed.
-- Nothing writes it yet -- deliberately, rather than adding an RPC with no
-- caller.
comment on column public.payments.confirmed_at is
  'When the payer acknowledged receipt. Informational since 20261124120008 -- NOT a payment gate. Nothing writes it yet.';

comment on column public.payments.delivered_at is
  'When the payee delivered. Setting this is what releases the money, via the release-payment Edge Function, which transfers and then stamps it.';

comment on table public.payments is
  'The ledger behind the Transactions screens. Release rule: the payee delivering the clip transfers money to them -- enforced in supabase/functions/release-payment, since the transfer is a Stripe call.';

-- mark_payment_delivered stays payee-only and keeps its state and idempotency
-- guards, but it is no longer the whole story: delivery now has to move money,
-- which Postgres cannot do. The Edge Function calls this and then transfers, so
-- a client calling this RPC directly would record a delivery that never paid.
-- Locked down to match: only the service role may call it now.
revoke execute on function public.mark_payment_delivered(uuid) from authenticated;
