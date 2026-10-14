-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260928090611, name '38_payment_methods_change_mode'. This is the SQL that actually ran.

insert into public.permissions (key, description, is_sensitive)
values ('payment.change_mode', 'Change how a paid bill was paid (e.g. cash to UPI)', true)
on conflict (key) do nothing;
-- Owners and managers of existing restaurants get the new right.
insert into public.role_permissions (role_id, permission_key)
select r.id, 'payment.change_mode' from public.roles r
 where r.name in ('Owner', 'Manager') and r.is_system
on conflict do nothing;

-- Payments stay immutable, except a controlled change of the payment method.
create or replace function app.guard_payment_update() returns trigger
language plpgsql set search_path to 'public','pg_temp' as $$
begin
  if coalesce(current_setting('app.pay_fix', true), '') = 'on'
     and old.status = 'captured' and new.status = 'captured'
     and (to_jsonb(new) - 'payment_method_id' - 'tendered_amount' - 'change_amount' - 'reference_no' - 'updated_at')
         is not distinct from
         (to_jsonb(old) - 'payment_method_id' - 'tendered_amount' - 'change_amount' - 'reference_no' - 'updated_at') then
    return new;
  end if;
  if (to_jsonb(new) - 'status' - 'updated_at') is distinct from (to_jsonb(old) - 'status' - 'updated_at')
     or not (old.status = 'captured' and new.status = 'refunded') then
    raise exception 'Payments cannot be changed.';
  end if;
  return new;
end $$;

create or replace function public.change_payment_method(p_payment_id uuid, p_method_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare
  v_user uuid := app.require_permission('payment.change_mode');
  p public.payments%rowtype; o public.orders%rowtype; v_old text; v_new text; v_new_kind text; v_shift_open boolean;
begin
  if length(trim(coalesce(p_reason, ''))) < 3 then raise exception 'Write a short reason for the change.'; end if;
  select * into p from public.payments where id = p_payment_id and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'Payment not found.'; end if;
  if p.status <> 'captured' then raise exception 'This payment was refunded and cannot be changed.'; end if;
  select * into o from public.orders where id = p.order_id for update;
  if o.status = 'voided' then raise exception 'Bill % is voided.', o.bill_number; end if;
  select s.status = 'open' into v_shift_open from public.shifts s where s.id = o.shift_id;
  if not coalesce(v_shift_open, false) then
    raise exception 'The shift for bill % is already closed, so the payment mode can no longer be changed.', o.bill_number;
  end if;
  if coalesce(p.rounding_adjustment, 0) <> 0 then
    raise exception 'This cash payment was rounded, so its mode cannot be changed. Void and re-bill instead.';
  end if;
  if p.payment_method_id = p_method_id then raise exception 'That is already the payment method.'; end if;
  select pm.name, pm.kind into v_new, v_new_kind from public.payment_methods pm
   where pm.id = p_method_id and pm.restaurant_id = p.restaurant_id and pm.is_active;
  if not found then raise exception 'That payment method is not available.'; end if;
  select name into v_old from public.payment_methods where id = p.payment_method_id;

  perform set_config('app.pay_fix', 'on', true);
  update public.payments set payment_method_id = p_method_id,
         tendered_amount = case when v_new_kind = 'cash' then amount else null end,
         change_amount = 0,
         reference_no = case when v_new_kind = 'cash' then null else reference_no end
   where id = p.id;
  perform set_config('app.pay_fix', 'off', true);

  perform app.audit('payment.change_mode', 'payments', p.id,
    jsonb_build_object('bill_number', o.bill_number, 'method', v_new, 'amount', p.amount, 'reason', left(trim(p_reason), 200)),
    jsonb_build_object('method', v_old));
  return jsonb_build_object('bill_number', o.bill_number, 'from', v_old, 'to', v_new);
end $$;
revoke all on function public.change_payment_method(uuid,uuid,text) from public, anon;
grant execute on function public.change_payment_method(uuid,uuid,text) to authenticated;

-- Add or rename a payment method (e.g. "GCash", "Paytm", "Swiggy Dineout").
create or replace function public.save_payment_method(p_id uuid, p_name text, p_kind text, p_ask_reference boolean default false, p_upi_id text default null)
returns uuid language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare
  v_user uuid := app.require_permission('settings.manage');
  v_rest uuid := app.current_restaurant_id();
  v_name text := btrim(coalesce(p_name, ''));
  v_upi text := nullif(btrim(coalesce(p_upi_id, '')), '');
  v_old public.payment_methods%rowtype; v_id uuid; v_used boolean;
begin
  if v_name = '' or length(v_name) > 30 then raise exception 'Give the payment method a name (up to 30 letters).'; end if;
  if coalesce(p_kind, '') not in ('cash', 'card', 'wallet', 'bank_transfer', 'upi', 'other') then raise exception 'Choose what kind of payment it is.'; end if;
  if v_upi is not null and p_kind <> 'upi' then v_upi := null; end if;
  if v_upi is not null and v_upi !~ '^[A-Za-z0-9._-]{2,200}@[A-Za-z][A-Za-z0-9]{1,63}$' then
    raise exception 'That UPI ID does not look right. It should look like shopname@okbank.';
  end if;
  if exists (select 1 from public.payment_methods where restaurant_id = v_rest and lower(name) = lower(v_name)
               and id is distinct from p_id) then
    raise exception 'A payment method called % already exists.', v_name;
  end if;
  if p_id is null then
    insert into public.payment_methods (restaurant_id, name, kind, affects_cash_drawer, is_active, display_order, ask_reference, upi_id)
    values (v_rest, v_name, p_kind, p_kind = 'cash', true,
            coalesce((select max(display_order) + 1 from public.payment_methods where restaurant_id = v_rest), 0),
            coalesce(p_ask_reference, false) and p_kind <> 'cash', v_upi)
    returning id into v_id;
    perform app.audit('payment_method.created', 'payment_methods', v_id, jsonb_build_object('name', v_name, 'kind', p_kind));
  else
    select * into v_old from public.payment_methods where id = p_id and restaurant_id = v_rest for update;
    if not found then raise exception 'Payment method not found.'; end if;
    select exists (select 1 from public.payments where payment_method_id = p_id) into v_used;
    if v_used and v_old.kind <> p_kind and (v_old.kind = 'cash' or p_kind = 'cash') then
      raise exception '% already has payments, so it cannot be switched to or from cash. Add a new method instead.', v_old.name;
    end if;
    update public.payment_methods set name = v_name, kind = p_kind, affects_cash_drawer = (p_kind = 'cash'),
           ask_reference = coalesce(p_ask_reference, false) and p_kind <> 'cash', upi_id = v_upi
     where id = p_id;
    v_id := p_id;
    perform app.audit('payment_method.changed', 'payment_methods', v_id,
      jsonb_build_object('name', v_name, 'kind', p_kind, 'upi_id', v_upi),
      jsonb_build_object('name', v_old.name, 'kind', v_old.kind, 'upi_id', v_old.upi_id));
  end if;
  return v_id;
end $$;
revoke all on function public.save_payment_method(uuid,text,text,boolean,text) from public, anon;
grant execute on function public.save_payment_method(uuid,text,text,boolean,text) to authenticated;
