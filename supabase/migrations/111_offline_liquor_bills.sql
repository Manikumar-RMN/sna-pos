-- 111: Liquor bills made offline get their own numbers too.
-- The offline copy of the menu now carries the outlet's liquor bill prefix and the device's next liquor number.
-- A liquor bill made offline is numbered <liquor prefix>-X<device>-<seq> (e.g. BAR26-X1-0001); food bills keep
-- <bill prefix>-X<device>-<seq>. When it syncs it is saved as a liquor bill. (Mixing liquor and food on one bill is
-- refused on the device, as it is online.)

alter table public.offline_series add column liquor_next_seq integer not null default 1 check (liquor_next_seq >= 1);

-- The outlet's liquor prefix, making the series on first use; null when the restaurant has no liquor tax group.
create or replace function app.offline_liquor_code(p_branch uuid)
returns text
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_rest uuid; v_p text; v_base text; v_try text; n int := 1;
begin
  select restaurant_id into v_rest from public.branches where id = p_branch;
  if not exists (select 1 from public.tax_groups where restaurant_id = v_rest and separate_bill) then return null; end if;
  select prefix into v_p from public.liquor_series where branch_id = p_branch;
  if v_p is not null then return v_p; end if;
  perform pg_advisory_xact_lock(hashtext('liquor_series:' || p_branch::text));
  v_base := 'BAR' || to_char(now(), 'YY'); v_try := v_base;
  while exists (select 1 from public.liquor_series where restaurant_id = v_rest and upper(prefix) = upper(v_try))
     or exists (select 1 from public.bill_series where restaurant_id = v_rest and upper(prefix) = upper(v_try)) loop
    n := n + 1; v_try := left(v_base, 7 - length(n::text)) || n;
  end loop;
  insert into public.liquor_series (restaurant_id, branch_id, prefix) values (v_rest, p_branch, v_try) on conflict (branch_id) do nothing;
  return (select prefix from public.liquor_series where branch_id = p_branch);
end $function$;
revoke all on function app.offline_liquor_code(uuid) from public, anon, authenticated;

do $patch$
declare d text; a text;
begin
  -- The offline copy carries the liquor prefix and next liquor number.
  d := pg_get_functiondef('public.offline_snapshot'::regproc);
  a := '''branch_code'', ser.series_key, ''key'', ser.series_key),';
  if position(a in d) = 0 then raise exception 'offline_snapshot is not the expected version.'; end if;
  execute replace(d, a, '''branch_code'', ser.series_key, ''key'', ser.series_key,
                                 ''liquor_code'', app.offline_liquor_code(v_branch), ''liquor_next_seq'', ser.liquor_next_seq),');

  -- Sync: accept the liquor prefix, save such a bill as a liquor bill, keep its own next number.
  d := pg_get_functiondef('public.sync_offline_bill'::regproc);
  a := '  v_ref uuid; ser public.offline_series; v_seq int; v_no text; v_expected text; v_at timestamptz;';
  if position(a in d) = 0 then raise exception 'sync_offline_bill (declare) is not the expected version.'; end if;
  d := replace(d, a, a || ' v_liq boolean := false;');
  a := '          and exists (select 1 from public.bill_series bs2 where bs2.branch_id = v_branch
                       and bs2.prefix = left(v_no, length(v_no) - length(v_expected)))) then';
  if position(a in d) = 0 then raise exception 'sync_offline_bill (number check) is not the expected version.'; end if;
  d := replace(d, a, '          and (exists (select 1 from public.bill_series bs2 where bs2.branch_id = v_branch
                       and bs2.prefix = left(v_no, length(v_no) - length(v_expected)))
               or exists (select 1 from public.liquor_series ls where ls.branch_id = v_branch
                       and ls.prefix = left(v_no, length(v_no) - length(v_expected))))) then');
  a := '  if exists (select 1 from public.orders where branch_id = v_branch and bill_number = v_no) then';
  if position(a in d) = 0 then raise exception 'sync_offline_bill (used check) is not the expected version.'; end if;
  d := replace(d, a, '  v_liq := exists (select 1 from public.liquor_series ls where ls.branch_id = v_branch and v_no like ls.prefix || ''-X%'');
' || a);
  a := '  insert into public.orders (id, restaurant_id, branch_id, device_id, bill_number, order_type, cashier_id, shift_id, currency_code,';
  if position(a in d) = 0 then raise exception 'sync_offline_bill (insert) is not the expected version.'; end if;
  d := replace(d, a, '  perform set_config(''app.liquor_bill'', case when v_liq then ''on'' else '''' end, true);
' || a);
  a := '  update public.offline_series set next_seq = greatest(next_seq, v_seq + 1), last_sync_at = now() where id = ser.id;';
  if position(a in d) = 0 then raise exception 'sync_offline_bill (next number) is not the expected version.'; end if;
  d := replace(d, a, '  if v_liq then
    update public.offline_series set liquor_next_seq = greatest(liquor_next_seq, v_seq + 1), last_sync_at = now() where id = ser.id;
  else
' || a || '
  end if;');
  execute d;
end $patch$;
