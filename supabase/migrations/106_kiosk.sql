-- 106: Self-order kiosk.
-- A kiosk is a tablet at the counter running the guest ordering page. It is set up like a table with a QR link,
-- but it is not a table: it is not offered for dine-in billing, it takes many orders one after another, and each
-- accepted kiosk order becomes its own takeaway bill (with a token number when tokens are on). The guest pays at the
-- counter; the kiosk screen shows the token once the staff accept the order.

alter table public.dining_tables add column is_kiosk boolean not null default false;

create or replace function public.kiosk_add(p_name text)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_user uuid := app.require_permission('settings.manage'); v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
  v_name text := btrim(coalesce(p_name, '')); v_id uuid; v_token text := app.new_token();
begin
  perform app.require_feature('qr_ordering');
  if v_name = '' or length(v_name) > 20 then raise exception 'Give the kiosk a short name, for example Kiosk 1.'; end if;
  if exists (select 1 from public.dining_tables where branch_id = v_branch and lower(table_number) = lower(v_name) and is_active) then
    raise exception 'There is already a table or kiosk called %.', v_name;
  end if;
  insert into public.dining_tables (restaurant_id, branch_id, table_number, seats, is_kiosk, qr_token)
  values (v_rest, v_branch, v_name, 1, true, v_token)
  on conflict (branch_id, table_number) do update set is_active = true, is_kiosk = true, qr_token = coalesce(public.dining_tables.qr_token, excluded.qr_token)
  returning id, qr_token into v_id, v_token;
  return jsonb_build_object('id', v_id, 'name', v_name, 'token', v_token);
end $function$;

create or replace function public.kiosk_list()
returns jsonb
language sql
stable security definer
set search_path to 'public', 'pg_temp'
as $function$
  select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'name', t.table_number, 'token', t.qr_token) order by t.table_number), '[]'::jsonb)
    from public.dining_tables t
   where t.restaurant_id = app.current_restaurant_id() and t.branch_id = app.current_branch_id() and t.is_kiosk and t.is_active
     and app.allowed('settings.manage')
$function$;

create or replace function public.kiosk_remove(p_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_user uuid := app.require_permission('settings.manage');
begin
  update public.dining_tables set is_active = false where id = p_id and is_kiosk and restaurant_id = app.current_restaurant_id();
  if not found then raise exception 'That kiosk was not found.'; end if;
end $function$;

revoke all on function public.kiosk_add(text), public.kiosk_list(), public.kiosk_remove(uuid) from public, anon;
grant execute on function public.kiosk_add(text), public.kiosk_list(), public.kiosk_remove(uuid) to authenticated, service_role;

-- What the guest sees after ordering: once accepted, the bill number and token.
create or replace function public.qr_order_status(p_request uuid, p_key text)
returns jsonb
language sql
stable security definer
set search_path to 'public', 'pg_temp'
as $function$
  select jsonb_build_object('status', q.status, 'reason', q.reject_reason, 'estimated_total', q.estimated_total,
                            'bill_number', o.bill_number, 'token_no', o.token_no)
    from public.qr_orders q left join public.orders o on o.id = q.order_id
   where q.id = p_request and q.guest_key = p_key;
$function$;

do $patch$
declare d text; n int;
begin
  -- Guest page: knows it is a kiosk.
  d := pg_get_functiondef('public.qr_menu'::regproc);
  if position('''table'', t.table_number,' in d) = 0 then raise exception 'qr_menu is not the expected version.'; end if;
  execute replace(d, '''table'', t.table_number,', '''table'', t.table_number, ''kiosk'', t.is_kiosk,');

  -- Placing orders: the per-table limits do not apply to a kiosk (one guest after another).
  d := pg_get_functiondef('public.qr_place_order'::regproc);
  if position('  if (select count(*) from public.qr_orders q where q.dining_table_id = t.id and q.status = ''pending'') >= 3 then' in d) = 0
     or position('  if (select count(*) from public.qr_orders q where q.dining_table_id = t.id and q.created_at > now() - interval ''10 minutes'') >= 8 then' in d) = 0 then
    raise exception 'qr_place_order is not the expected version.';
  end if;
  d := replace(d, '  if (select count(*) from public.qr_orders q where q.dining_table_id = t.id and q.status = ''pending'') >= 3 then',
                  '  if (select count(*) from public.qr_orders q where q.dining_table_id = t.id and q.status = ''pending'') >= greatest(3, 30 * t.is_kiosk::int) then');
  d := replace(d, '  if (select count(*) from public.qr_orders q where q.dining_table_id = t.id and q.created_at > now() - interval ''10 minutes'') >= 8 then',
                  '  if (select count(*) from public.qr_orders q where q.dining_table_id = t.id and q.created_at > now() - interval ''10 minutes'') >= greatest(8, 60 * t.is_kiosk::int) then');
  execute d;

  -- Accepting: a kiosk order is always a new takeaway bill without a table.
  d := pg_get_functiondef('public.accept_qr_order'::regproc);
  if position('  select o.id into v_order from public.orders o' in d) = 0
     or position('    v_res := public.create_order(q.items, ''dine_in'', q.dining_table_id, null, null, null, 0, null, null, null, null, null);' in d) = 0 then
    raise exception 'accept_qr_order is not the expected version.';
  end if;
  d := replace(d, '  select o.id into v_order from public.orders o',
                  '  if not coalesce((select is_kiosk from public.dining_tables where id = q.dining_table_id), false) then
  select o.id into v_order from public.orders o');
  d := replace(d, '   order by o.created_at desc limit 1;',
                  '   order by o.created_at desc limit 1;
  end if;');
  d := replace(d, '    v_res := public.create_order(q.items, ''dine_in'', q.dining_table_id, null, null, null, 0, null, null, null, null, null);',
                  '    if coalesce((select is_kiosk from public.dining_tables where id = q.dining_table_id), false) then
      v_res := public.create_order(q.items, ''takeaway'', null, null, null, null, 0, null, null, null, null, null);
    else
      v_res := public.create_order(q.items, ''dine_in'', q.dining_table_id, null, null, null, 0, null, null, null, null, null);
    end if;');
  execute d;

  -- Table QR codes: kiosks are listed separately.
  d := pg_get_functiondef('public.table_qr_codes'::regproc);
  if position('from public.dining_tables t where t.restaurant_id = v_rest and t.branch_id = v_branch and t.is_active)' in d) = 0 then
    raise exception 'table_qr_codes is not the expected version.';
  end if;
  execute replace(d, 'from public.dining_tables t where t.restaurant_id = v_rest and t.branch_id = v_branch and t.is_active)',
                     'from public.dining_tables t where t.restaurant_id = v_rest and t.branch_id = v_branch and t.is_active and not t.is_kiosk)');
end $patch$;
