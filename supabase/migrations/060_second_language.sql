-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260928104456, name '060_second_language'. This is the SQL that actually ran.

alter table public.restaurants add column if not exists second_language text
  check (second_language in ('hi','ta','te','kn','ml','mr','bn','gu','pa','or','ur','as','ar','ms','id','th','fil','zh'));
alter table public.products add column if not exists name_local text check (name_local is null or length(name_local) <= 120);
alter table public.order_items add column if not exists product_name_local text;
alter table public.kitchen_ticket_items add column if not exists product_name_local text;

-- Bills and kitchen tickets keep the dish name in the second language as it was when ordered.
create or replace function app.fill_local_name() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if tg_table_name = 'order_items' then
    if new.product_name_local is null and new.product_id is not null then
      select p.name_local into new.product_name_local from public.products p where p.id = new.product_id;
    end if;
  elsif tg_table_name = 'kitchen_ticket_items' then
    if new.product_name_local is null and new.order_item_id is not null then
      select oi.product_name_local into new.product_name_local from public.order_items oi where oi.id = new.order_item_id;
    end if;
  end if;
  return new;
end $$;
create trigger trg_fill_local_name before insert on public.order_items for each row execute function app.fill_local_name();
create trigger trg_fill_local_name before insert on public.kitchen_ticket_items for each row execute function app.fill_local_name();

create or replace function public.set_second_language(p_lang text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform app.require_permission('settings.manage');
  update public.restaurants set second_language = nullif(p_lang, '') where id = app.current_restaurant_id();
  perform app.audit('settings.second_language', 'restaurants', app.current_restaurant_id(), jsonb_build_object('language', p_lang));
end $$;
revoke all on function public.set_second_language(text) from public, anon;
grant execute on function public.set_second_language(text) to authenticated;

create or replace view public.v_menu with (security_invoker = true) as
 select p.id, p.restaurant_id, p.category_id, p.tax_group_id, p.name, p.short_name,
        coalesce(bp.price, p.price)::numeric(14,2) as price,
        p.is_veg,
        (p.is_available and coalesce(bp.is_available, true)) as is_available,
        p.display_order, c.name as category_name, c.display_order as category_order,
        tg.name as tax_group_name, tg.is_price_inclusive,
        (select tr.total_rate from public.tax_rates tr
          where tr.tax_group_id = p.tax_group_id and tr.valid_from <= current_date and (tr.valid_to is null or tr.valid_to >= current_date)
          order by tr.valid_from desc limit 1) as tax_rate,
        p.price as menu_price,
        p.name_local
   from public.products p
   join public.categories c on c.id = p.category_id
   join public.tax_groups tg on tg.id = p.tax_group_id
   left join public.branch_prices bp on bp.product_id = p.id and bp.branch_id = (select app.current_branch_id())
  where p.deleted_at is null and c.deleted_at is null;

create or replace view public.v_current_user as
 select u.id as user_id, u.restaurant_id, u.full_name, u.email, u.employee_code,
        r.id as role_id, r.name as role_name, res.trading_name, res.country_code, res.currency_code, res.timezone,
        (select coalesce(array_agg(rp.permission_key order by rp.permission_key), '{}'::text[])
           from public.role_permissions rp where rp.role_id = r.id) as permissions,
        u.must_change_password,
        (select d.name from public.devices d where d.id = app.device_id()) as device_name,
        res.edition,
        (select coalesce(array_agg(m.key order by m.key), '{}'::text[])
           from public.modules m where app.feature_on(res.id, m.key)) as features,
        (app.sna_staff_id() is not null) as is_sna_staff,
        app.current_branch_id() as branch_id,
        (select b.name from public.branches b where b.id = app.current_branch_id()) as branch_name,
        (select count(*)::int from public.branches b where b.restaurant_id = res.id and b.deleted_at is null) as outlet_count,
        res.second_language
   from public.users u
   join public.roles r on r.id = u.role_id
   join public.restaurants res on res.id = u.restaurant_id
  where u.id = app.current_user_id();
