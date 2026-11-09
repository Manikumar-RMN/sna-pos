-- 183: reports follow the modules. The stock reports (Purchase and inventory) need the stock module and the
-- loyalty ledger needs the loyalty module, checked in the database as well as on screen.

do $$
declare
  spec jsonb := jsonb_build_object(
    'stock', jsonb_build_array('report_stock_on_hand','report_stock_movement','report_food_cost','report_wastage'),
    'loyalty', jsonb_build_array('report_loyalty_ledger')
  );
  m text; fn text; f record; def text; newdef text; newbody text; n int := 0; missing text := '';
begin
  for m in select jsonb_object_keys(spec) loop
    for fn in select jsonb_array_elements_text(spec -> m) loop
      if not exists (select 1 from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = fn) then
        missing := missing || fn || ' ';
        continue;
      end if;
      for f in select p.oid, p.prosrc, l.lanname
                 from pg_proc p join pg_namespace s on s.oid = p.pronamespace join pg_language l on l.oid = p.prolang
                where s.nspname = 'public' and p.proname = fn loop
        if f.prosrc like '%require_feature(''' || m || '''%' then continue; end if;
        def := pg_get_functiondef(f.oid);
        if f.lanname = 'plpgsql' then
          newdef := regexp_replace(def, E'\\mbegin\\s*\\n', E'begin\n  perform app.require_feature(''' || m || E''');\n', '');
        elsif f.lanname = 'sql' then
          -- a plain SQL function is rewritten as plpgsql so the check can run first
          newbody := E'\nbegin\n  perform app.require_feature(''' || m || E''');\n  return (' || rtrim(btrim(f.prosrc, E' \n\r\t'), ';') || E');\nend\n';
          newdef := replace(replace(def, f.prosrc, newbody), 'LANGUAGE sql', 'LANGUAGE plpgsql');
        else
          raise exception 'Function % uses language %; patch it by hand.', fn, f.lanname;
        end if;
        if newdef = def then raise exception 'Could not patch %', fn; end if;
        execute newdef;
        n := n + 1;
      end loop;
    end loop;
  end loop;
  if missing <> '' then raise exception 'Functions not found: %', missing; end if;
  raise notice 'Patched % functions', n;
end $$;

