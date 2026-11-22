-- 265: the client page's sales list also carries each sale's due date.
do $m$
declare d text;
begin
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'sna_client' and pg_get_function_identity_arguments(p.oid) = 'p_id uuid';
  if d like '%''due_on''%' then return; end if;
  d := replace(d, '''paid_on'', s.paid_on,', '''paid_on'', s.paid_on, ''due_on'', s.due_on,');
  if d not like '%''due_on''%' then raise exception 'sna_client was not changed'; end if;
  execute d;
end $m$;
