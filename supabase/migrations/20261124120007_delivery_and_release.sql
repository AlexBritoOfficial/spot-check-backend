-- Delivery and the confirmation that releases the money.
--
-- The canvas draws escrow as a four-step trail (ClipVaultScreen.swift:55-60):
--
--     Charged & held -> Both confirmed -> Raw clips delivered -> Filmer paid
--
-- 20261124120002 modelled the first step and the last one (`held`,
-- `released`), but nothing in between. These two columns are the middle:
--
--   delivered_at  the filmer handed over the raw clips -- ClipUpload's
--                 "Deliver to Rider Silva" button
--   confirmed_at  the skater confirmed they received them, which is what
--                 releases the money to the filmer (Alex, 2026-11-24)
--
-- Deliberately NOT modelled here: step 2, "both confirmed the session
-- happened", which is a separate pair of confirmations about the session
-- taking place rather than about the clips. It needs its own pass, and
-- nothing below depends on it.

alter table public.payments
  add column delivered_at timestamptz,
  add column confirmed_at timestamptz;

-- Neither is client-writable, and not because of a column GRANT: `payments`
-- has a SELECT policy and no insert/update/delete policy at all, so RLS
-- denies every write outright. The only paths in are the security definer
-- function below and the service role (the Stripe functions).
--
-- That matters most for confirmed_at: a skater who could set it themselves
-- could not steal anything, but a *filmer* who could set it could release
-- their own escrow without the skater ever seeing a clip.

comment on column public.payments.delivered_at is
  'When the payee handed over the deliverable. Set only by mark_payment_delivered.';
comment on column public.payments.confirmed_at is
  'When the payer confirmed receipt. Setting this is what releases the money; written only by the release-payment Edge Function.';

comment on table public.payments is
  'The ledger behind the Transactions screens. Release rule: the payer confirming receipt of the deliverable is what transfers money to the payee -- enforced in supabase/functions/release-payment, not here, because the transfer itself is a Stripe call.';

-- ---------------------------------------------------------------------------
-- The filmer's half: delivery
-- ---------------------------------------------------------------------------

-- Security definer because `payments` has no write policy. The authorization
-- is therefore this function's own business, and it is the payee check below:
-- without it, anyone could mark anyone's session delivered.
create or replace function public.mark_payment_delivered(p_payment_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_payee uuid;
  v_state public.payment_state;
  v_delivered timestamptz;
begin
  select p.payee_id, p.state, p.delivered_at
    into v_payee, v_state, v_delivered
    from public.payments p
   where p.id = p_payment_id;

  if not found then
    raise exception 'no such payment %', p_payment_id using errcode = '22023';
  end if;

  -- The person being paid is the one who delivers.
  if v_payee is distinct from auth.uid() then
    raise exception 'only the payee can mark a payment delivered'
      using errcode = '42501';
  end if;

  -- Only money that is actually being held can be delivered against. Blocks
  -- marking a refunded or declined session delivered to force a release.
  if v_state <> 'held' then
    raise exception 'payment is %, not held', v_state using errcode = '22023';
  end if;

  -- Idempotent: ClipUpload's button can be tapped twice, and the second tap
  -- must not move the timestamp or append a second timeline row.
  if v_delivered is not null then
    return;
  end if;

  update public.payments
     set delivered_at = now()
   where id = p_payment_id;

  -- The state does not change -- the money stays held until the skater
  -- confirms -- but TransactionDetail's STATUS list is a history, so delivery
  -- still belongs on it.
  insert into public.payment_events (payment_id, state, note)
  values (p_payment_id, 'held', 'Raw clips delivered');
end;
$$;

-- Callable by signed-in users: the payee check inside is the gate, not the
-- GRANT. Contrast record_payment_event, which is revoked from everyone
-- because no client should ever move money state directly.
revoke all on function public.mark_payment_delivered(uuid) from public, anon;
grant execute on function public.mark_payment_delivered(uuid) to authenticated;
