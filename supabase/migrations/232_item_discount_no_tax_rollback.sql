-- Rollback for 232. Restores the three bill functions from the backup copies taken just before 232 was applied.
-- (The columns and the new functions can stay; nothing reads them once the old functions are back.)
do $$ declare d text; begin
  d := replace(pg_get_functiondef('app.calc_bill_v231(jsonb)'::regprocedure), 'FUNCTION app.calc_bill_v231(', 'FUNCTION app.calc_bill(');
  execute d;
  d := replace(pg_get_functiondef('app.recalc_order_v231(uuid)'::regprocedure), 'FUNCTION app.recalc_order_v231(', 'FUNCTION app.recalc_order(');
  execute d;
  d := replace(pg_get_functiondef('app.adjust_order_v231(uuid,numeric,text,boolean)'::regprocedure), 'FUNCTION app.adjust_order_v231(', 'FUNCTION public.adjust_order(');
  execute d;
end $$;
drop function if exists public.set_item_discount(uuid,uuid,text,numeric,text);
drop function if exists public.set_category_discount(uuid,uuid,numeric,text);
drop function if exists public.set_bill_no_tax(uuid,boolean,text);
