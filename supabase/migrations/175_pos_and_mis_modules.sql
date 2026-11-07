-- 175: POS and Reports/MIS become switchable modules, so a client who bought only Front Office does not see them.
--
-- Same mechanism as every other module: a row in public.modules, and a row in public.restaurant_modules for each client that has it
-- (sna_set_module switches it on or off). Every EXISTING restaurant is given both rows here, so nothing disappears for anyone who
-- already uses POS. Every NEW restaurant gets both by default (trigger below); sales staff switch POS off for a front-office-only sale.
-- No monthly price is attached (plan_prices has no row for these keys), so billing does not change.
-- This hides the screens. It does not yet make the database refuse POS calls from a client without the module.
-- Safe to run again.

insert into public.modules (key, name, description, kind, display_order) values
  ('pos',         'POS billing and kitchen', 'Billing, tables, kitchen, shifts and day close', 'addon', 0),
  ('reports_mis', 'Reports and MIS',         'Sales, financial and customer reports',          'addon', 30)
on conflict (key) do nothing;

insert into public.restaurant_modules (restaurant_id, module_key)
select r.id, m.key from public.restaurants r cross join (values ('pos'), ('reports_mis')) m(key)
on conflict do nothing;

create or replace function app.trg_default_modules() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  insert into public.restaurant_modules (restaurant_id, module_key)
  values (new.id, 'pos'), (new.id, 'reports_mis') on conflict do nothing;
  return new;
end $$;
revoke all on function app.trg_default_modules() from public, anon, authenticated;

drop trigger if exists trg_default_modules on public.restaurants;
create trigger trg_default_modules after insert on public.restaurants
  for each row execute function app.trg_default_modules();
