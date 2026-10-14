-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260927171736, name '32_hardening_menu_audit_refund_off'. This is the SQL that actually ran.

-- 32: hardening agreed by the Founder on 27 Sep 2026

-- (a) anonymous visitors get no table access at all; signed-in users lose table-level TRUNCATE/TRIGGER/REFERENCES
revoke all on all tables in schema public from anon;
revoke truncate, trigger, references on all tables in schema public from authenticated;
alter default privileges in schema public revoke all on tables from anon;
alter default privileges in schema public revoke truncate, trigger, references on tables from authenticated;

-- (b) audit log and refunds can never be edited; payments may only move captured -> refunded (used by void)
create or replace function app.block_update() returns trigger language plpgsql set search_path = public, pg_temp as $$
begin
  raise exception '% records cannot be changed.', initcap(replace(tg_table_name, '_', ' '));
end $$;
create trigger trg_no_update_audit before update on public.audit_logs for each row execute function app.block_update();
create trigger trg_no_update_refunds before update on public.refunds for each row execute function app.block_update();
create trigger trg_no_delete_refunds before delete on public.refunds for each row execute function app.block_update();

create or replace function app.guard_payment_update() returns trigger language plpgsql set search_path = public, pg_temp as $$
begin
  if (to_jsonb(new) - 'status' - 'updated_at') is distinct from (to_jsonb(old) - 'status' - 'updated_at')
     or not (old.status = 'captured' and new.status = 'refunded') then
    raise exception 'Payments cannot be changed.';
  end if;
  return new;
end $$;
create trigger trg_guard_payment_update before update on public.payments for each row execute function app.guard_payment_update();

-- (c) menu: a price change needs "Change prices", a tax-group change needs "Change tax"; every change is logged
create or replace function app.guard_product_change() returns trigger language plpgsql set search_path = public, pg_temp as $$
begin
  if current_user not in ('authenticated', 'anon') then return new; end if;  -- trusted server functions
  if tg_op = 'UPDATE' then
    if new.price is distinct from old.price and not app.has_permission('menu.price_change') then
      raise exception 'You do not have the right to change prices.';
    end if;
    if new.tax_group_id is distinct from old.tax_group_id and not app.has_permission('tax.manage') then
      raise exception 'You do not have the right to change the tax on an item.';
    end if;
    if new.price is distinct from old.price or new.tax_group_id is distinct from old.tax_group_id then
      perform app.audit('menu.price_or_tax_changed', 'product', new.id,
        jsonb_build_object('name', new.name, 'price', new.price, 'tax_group_id', new.tax_group_id),
        jsonb_build_object('price', old.price, 'tax_group_id', old.tax_group_id));
    end if;
  else
    perform app.audit('menu.item_added', 'product', new.id,
      jsonb_build_object('name', new.name, 'price', new.price, 'tax_group_id', new.tax_group_id));
  end if;
  return new;
end $$;
create trigger trg_guard_product_change after insert or update on public.products for each row execute function app.guard_product_change();

-- (d) only one open shift per branch, even if two people press "Open shift" at the same moment
create unique index if not exists shifts_one_open_per_branch on public.shifts (branch_id) where status = 'open';

-- (e) Founder decision: refunds are switched off for now
do $mig$
declare d text := pg_get_functiondef('public.refund_order'::regproc);
begin
  d := regexp_replace(d, E'\nbegin\n', E'\nbegin\n  raise exception ''Refunds are switched off for now.'';\n');
  execute d;
end $mig$;

-- (f) Philippines senior / PWD discount needs the same "Give discount" right as any discount
do $mig$
declare d text := pg_get_functiondef('public.create_order'::regproc);
begin
  d := replace(d, $x$  if coalesce(p_discount_amount, 0) < 0 then$x$,
    $x$  if nullif(p_senior, 'null'::jsonb) is not null and not app.has_permission('order.discount') then
    raise exception 'You need the right to give discounts to apply a senior citizen / PWD discount.';
  end if;
  if coalesce(p_discount_amount, 0) < 0 then$x$);
  if d not like '%senior citizen / PWD discount%' then raise exception 'create_order patch did not apply'; end if;
  execute d;
end $mig$;
