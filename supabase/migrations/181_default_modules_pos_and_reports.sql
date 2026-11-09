-- 181: one version for everyone. Every new client starts with POS and POS reports (Reports and MIS).
-- Everything else (stock, QR ordering, loyalty, WhatsApp, owner app, customer display) is an add-on
-- the sales team switches on (sna_set_module, SNA console). Existing clients are not changed.
create or replace function app.trg_default_modules() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  insert into public.restaurant_modules (restaurant_id, module_key)
  values (new.id, 'pos'), (new.id, 'reports_mis')
  on conflict do nothing;
  return new;
end $$;

drop trigger if exists trg_default_modules on public.restaurants;
create trigger trg_default_modules after insert on public.restaurants
  for each row execute function app.trg_default_modules();
