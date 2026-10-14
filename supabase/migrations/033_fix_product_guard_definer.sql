-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260927171809, name '33_fix_product_guard_definer'. This is the SQL that actually ran.

create or replace function app.guard_product_change() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  -- no signed-in person (trusted server work); signed-in people without rights are already stopped by row security
  if app.current_user_id() is null then return new; end if;
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
revoke all on function app.guard_product_change() from public, anon, authenticated;
