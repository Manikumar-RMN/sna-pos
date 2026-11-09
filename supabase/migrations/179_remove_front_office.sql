-- 179: remove Front office and Housekeeping completely.
-- Founder decision, 9 Nov 2026. Drops every fo_* table and function, the POS room-charge hooks,
-- the fo.* permissions and the front_office module. One POS payment was taken on the "Room charge"
-- method; that payment stays, and the method is kept (switched off, kind 'other') so the bill and
-- the day's totals do not change.


-- POS hooks that looked at room charges
drop trigger if exists trg_room_charge_void on public.orders;
drop trigger if exists trg_room_charge_no_refund on public.refunds;
drop function if exists app.trg_room_charge_void();
drop function if exists app.trg_room_charge_no_refund();

-- The "Room charge" payment method: keep it for history, switch it off
alter table public.payment_methods drop constraint if exists payment_methods_kind_check;
update public.payment_methods
   set kind = 'other', is_active = false, name = 'Room charge (hotel module removed)'
 where kind = 'room';
alter table public.payment_methods add constraint payment_methods_kind_check
  check (kind = any (array['cash','card','wallet','bank_transfer','upi','other','gift_card','loyalty','advance','account']));

-- Tables
do $$
declare t text;
begin
  for t in select table_name from information_schema.tables
            where table_schema = 'public' and table_type = 'BASE TABLE' and table_name like 'fo\_%'
  loop
    execute format('drop table if exists public.%I cascade', t);
  end loop;
end $$;

-- Functions
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig
             from pg_proc p join pg_namespace s on s.oid = p.pronamespace
            where (s.nspname = 'public' and p.proname like 'fo\_%')
               or (s.nspname = 'app' and (p.proname = 'require_fo' or p.proname like 'fo\_%'))
  loop
    execute format('drop function if exists %s cascade', f.sig);
  end loop;
end $$;

-- Permissions, module, price
delete from public.role_permissions where permission_key like 'fo.%';
delete from public.permissions where key like 'fo.%';
delete from public.restaurant_modules where module_key = 'front_office';
delete from public.plan_prices where item = 'front_office';
delete from public.modules where key = 'front_office';

