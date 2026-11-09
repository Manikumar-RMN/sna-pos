-- 184: last traces of the removed hotel room-charge. The one old payment keeps a plain method name; the
-- payment guard no longer mentions rooms.
update public.payment_methods set name = 'Room charge (old)' where name = 'Room charge (hotel module removed)';

create or replace function app.guard_redeem_payment() returns trigger
language plpgsql set search_path = public, pg_temp as $$
declare k_new text; k_old text;
begin
  select kind into k_new from public.payment_methods where id = new.payment_method_id;
  if tg_op = 'INSERT' then
    if k_new in ('gift_card', 'loyalty') and coalesce(current_setting('app.redeem', true), '') <> 'on' then
      raise exception 'Use "Redeem gift card" or "Redeem points" on the bill for this payment.';
    end if;
    if k_new = 'advance' and coalesce(current_setting('app.advance', true), '') <> 'on' then
      raise exception 'A pre-order advance is applied with "Bill now" on the pre-order.';
    end if;
    if k_new = 'account' and coalesce(current_setting('app.account', true), '') <> 'on' then
      raise exception 'Use "Charge to account" on the bill for this payment.';
    end if;
  elsif new.payment_method_id is distinct from old.payment_method_id then
    select kind into k_old from public.payment_methods where id = old.payment_method_id;
    if k_new in ('gift_card', 'loyalty', 'advance', 'account') or k_old in ('gift_card', 'loyalty', 'advance', 'account') then
      raise exception 'A gift card, points, advance or account payment cannot be changed to another method, or the other way round.';
    end if;
  end if;
  return new;
end $$;
