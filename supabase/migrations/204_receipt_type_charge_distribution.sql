-- Receipt details: a receipt type, and the option to spread other charges (freight etc.) into stock cost.
alter table public.goods_receipts add column if not exists receipt_type text not null default 'purchase';
alter table public.goods_receipts add column if not exists charges_distributed boolean not null default false;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'goods_receipts_type_chk') then
    alter table public.goods_receipts add constraint goods_receipts_type_chk check (receipt_type in ('purchase','sample','replacement','transfer_in'));
  end if;
end $$;

do $$
declare d text; old regprocedure := 'public.receive_goods(uuid,jsonb,uuid,text,date,numeric,numeric,date,text,jsonb,uuid,date)'::regprocedure;
begin
  d := pg_get_functiondef(old);
  d := replace(d, 'p_received_on date DEFAULT NULL::date)', 'p_received_on date DEFAULT NULL::date, p_receipt_type text DEFAULT ''purchase'', p_distribute boolean DEFAULT false)');
  if d not like '%p_distribute%' then raise exception 'anchor 1'; end if;
  if position('v_man numeric(14,2) := 0;' in d) = 0 then raise exception 'anchor 2'; end if;
  d := replace(d, 'v_man numeric(14,2) := 0;', 'v_man numeric(14,2) := 0; v_all numeric := 0;');
  if position('  v_today := app.check_doc_date(p_received_on, false);' in d) = 0 then raise exception 'anchor 3'; end if;
  d := replace(d, '  v_today := app.check_doc_date(p_received_on, false);',
    E'  if coalesce(p_receipt_type, ''purchase'') not in (''purchase'',''sample'',''replacement'',''transfer_in'') then raise exception ''Choose a valid receipt type.''; end if;\n  if p_distribute and v_other > 0 then\n    select coalesce(sum(coalesce(x.line_total, round(x.qty * x.unit_cost, 2))), 0) into v_all from app.purchase_lines(v_rest, p_lines) x;\n  end if;\n  v_today := app.check_doc_date(p_received_on, false);');
  if position('    v_lsum := v_lsum + v_ltax;' in d) = 0 then raise exception 'anchor 4'; end if;
  d := replace(d, '    v_lsum := v_lsum + v_ltax;', E'    if p_distribute and v_all > 0 and v_other > 0 then v_eff := round(v_eff + v_other * v_amt / v_all / l.qty, 4); end if;\n    v_lsum := v_lsum + v_ltax;');
  if position('supplier_bill_date, received_on, due_on, notes, received_by, client_ref)' in d) = 0 then raise exception 'anchor 5'; end if;
  d := replace(d, 'supplier_bill_date, received_on, due_on, notes, received_by, client_ref)', 'supplier_bill_date, received_on, due_on, notes, received_by, client_ref, receipt_type, charges_distributed)');
  d := replace(d, 'nullif(left(trim(coalesce(p_notes, '''')), 300), ''''), v_user, p_client_ref);', 'nullif(left(trim(coalesce(p_notes, '''')), 300), ''''), v_user, p_client_ref, coalesce(p_receipt_type, ''purchase''), (p_distribute and v_other > 0));');
  if d not like '%charges_distributed)%' or d not like '%coalesce(p_receipt_type%, ''purchase''), (p_distribute%' then raise exception 'anchor 6'; end if;
  execute d;
  execute 'drop function ' || old::text;
  execute 'revoke all on function public.receive_goods(uuid,jsonb,uuid,text,date,numeric,numeric,date,text,jsonb,uuid,date,text,boolean) from public, anon';
  execute 'grant execute on function public.receive_goods(uuid,jsonb,uuid,text,date,numeric,numeric,date,text,jsonb,uuid,date,text,boolean) to authenticated';
end $$;
