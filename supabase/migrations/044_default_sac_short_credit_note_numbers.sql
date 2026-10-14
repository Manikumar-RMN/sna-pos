-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260928092108, name '44_default_sac_short_credit_note_numbers'. This is the SQL that actually ran.

create or replace function app.default_sac() returns trigger language plpgsql set search_path to 'public','pg_temp' as $$
begin
  if new.country_code = 'IN' and new.sac_code is null then new.sac_code := '996331'; end if;
  return new;
end $$;
drop trigger if exists trg_default_sac on public.restaurants;
create trigger trg_default_sac before insert on public.restaurants for each row execute function app.default_sac();

do $$
declare d text;
begin
  d := pg_get_functiondef('public.issue_credit_note(uuid,numeric,uuid,text)'::regprocedure);
  d := replace(d, E'  v_fy := app.fy_label(v_country, v_day.business_date);\n',
    E'  v_fy := app.fy_label(v_country, v_day.business_date);\n  if v_country = ''IN'' then v_fy := substr(v_fy, 3, 2) || substr(v_fy, 6, 2); end if;  -- 2026-27 -> 2627 (GST: max 16 characters)\n');
  if position('max 16 characters' in d) = 0 then raise exception 'patch failed'; end if;
  execute d;
end $$;
