-- The patched overloads of receive_goods and issue_material had kept the default "anyone may run" grant. Lock them to signed-in users.
revoke all on function public.receive_goods(uuid,jsonb,uuid,text,date,numeric,numeric,date,text,jsonb,uuid,date) from public, anon;
grant execute on function public.receive_goods(uuid,jsonb,uuid,text,date,numeric,numeric,date,text,jsonb,uuid,date) to authenticated;
revoke all on function public.issue_material(uuid,text,jsonb,text,uuid,date) from public, anon;
grant execute on function public.issue_material(uuid,text,jsonb,text,uuid,date) to authenticated;
