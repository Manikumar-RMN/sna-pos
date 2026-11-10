-- A paid receipt can now be returned. The part already paid becomes "refund due from the supplier"
-- (receipt paid_total minus its reduced total); nothing is refused any more.
do $$
declare d text; o text;
begin
  d := pg_get_functiondef('public.return_goods(uuid,jsonb,text,uuid)'::regprocedure); o := d;
  d := regexp_replace(d, E'  if v_total > g\\.total - g\\.paid_total then\\n.*?\\n  end if;\\n', '', 's');
  d := replace(d, '''owed'', g.total - v_total - g.paid_total);', '''owed'', greatest(0, g.total - v_total - g.paid_total), ''refund_due'', greatest(0, g.paid_total - (g.total - v_total)));');
  if d = o or position('v_total > g.total' in d) > 0 or position('refund_due' in d) = 0 then raise exception 'return_goods patch anchors changed'; end if;
  execute d;
end $$;
revoke all on function public.return_goods(uuid, jsonb, text, uuid) from public, anon;
grant execute on function public.return_goods(uuid, jsonb, text, uuid) to authenticated;
