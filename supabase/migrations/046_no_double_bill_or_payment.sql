-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260928092741, name '46_no_double_bill_or_payment'. This is the SQL that actually ran.

alter table public.orders add column client_ref uuid;
alter table public.payments add column client_ref uuid;
create unique index orders_client_ref_uq on public.orders (restaurant_id, client_ref) where client_ref is not null;
create unique index payments_client_ref_uq on public.payments (restaurant_id, client_ref) where client_ref is not null;

do $$
declare d text; g text;
begin
  -- create_order: same request id = same bill (a double tap or a network retry never makes a second bill).
  d := pg_get_functiondef('public.create_order(jsonb,text,uuid,uuid,uuid,numeric,numeric,text,boolean,jsonb,text)'::regprocedure);
  d := replace(d, 'p_reference text DEFAULT NULL::text)', 'p_reference text DEFAULT NULL::text, p_client_ref uuid DEFAULT NULL::uuid)');
  d := regexp_replace(d, E'\\nbegin\\n', E'\nbegin\n  if p_client_ref is not null then\n    perform pg_advisory_xact_lock(hashtext(''order_ref:'' || p_client_ref::text));\n    select jsonb_build_object(''order_id'', o.id, ''bill_number'', o.bill_number, ''grand_total'', o.grand_total,\n             ''amount_paid'', o.paid_total, ''cash_rounding'', 0, ''change'', 0, ''paid'', o.payment_status = ''paid'', ''repeat'', true)\n      into v_in from public.orders o where o.restaurant_id = app.current_restaurant_id() and o.client_ref = p_client_ref;\n    if v_in is not null then return v_in; end if;\n  end if;\n');
  d := replace(d, E'  v_ids := app.insert_order_lines(v_order_id, v_restaurant, v_in->''calc''->''lines'');\n',
                  E'  if p_client_ref is not null then update public.orders set client_ref = p_client_ref where id = v_order_id; end if;\n  v_ids := app.insert_order_lines(v_order_id, v_restaurant, v_in->''calc''->''lines'');\n');
  if position('order_ref:' in d) = 0 or position('set client_ref = p_client_ref' in d) = 0 then raise exception 'patch create_order failed'; end if;
  drop function public.create_order(jsonb,text,uuid,uuid,uuid,numeric,numeric,text,boolean,jsonb,text);
  execute d;

  -- pay_order: same request id = same payment.
  d := pg_get_functiondef('public.pay_order(uuid,uuid,numeric,numeric,text)'::regprocedure);
  d := replace(d, 'p_reference text DEFAULT NULL::text)', 'p_reference text DEFAULT NULL::text, p_client_ref uuid DEFAULT NULL::uuid)');
  d := regexp_replace(d, E'\\nbegin\\n', E'\nbegin\n  if p_client_ref is not null then\n    perform pg_advisory_xact_lock(hashtext(''pay_ref:'' || p_client_ref::text));\n    select * into o from public.orders where id = p_order_id and restaurant_id = app.current_restaurant_id();\n    if exists (select 1 from public.payments p where p.restaurant_id = app.current_restaurant_id() and p.client_ref = p_client_ref) then\n      return jsonb_build_object(''order_id'', o.id, ''bill_number'', o.bill_number, ''amount'', 0, ''cash_rounding'', 0, ''change'', 0,\n        ''paid'', o.payment_status = ''paid'', ''balance'', o.grand_total - app.order_covered(o.id), ''repeat'', true);\n    end if;\n  end if;\n');
  d := replace(d, 'change_amount, status, received_by, client_created_at, rounding_adjustment, reference_no)', 'change_amount, status, received_by, client_created_at, rounding_adjustment, reference_no, client_ref)');
  d := replace(d, 'v_round, nullif(left(trim(p_reference), 60), ''''));', 'v_round, nullif(left(trim(p_reference), 60), ''''), p_client_ref);');
  if position('pay_ref:' in d) = 0 or position('p_client_ref);' in d) = 0 then raise exception 'patch pay_order failed'; end if;
  drop function public.pay_order(uuid,uuid,numeric,numeric,text);
  execute d;
end $$;
revoke all on function public.create_order(jsonb,text,uuid,uuid,uuid,numeric,numeric,text,boolean,jsonb,text,uuid) from public, anon;
grant execute on function public.create_order(jsonb,text,uuid,uuid,uuid,numeric,numeric,text,boolean,jsonb,text,uuid) to authenticated;
revoke all on function public.pay_order(uuid,uuid,numeric,numeric,text,uuid) from public, anon;
grant execute on function public.pay_order(uuid,uuid,numeric,numeric,text,uuid) to authenticated;
