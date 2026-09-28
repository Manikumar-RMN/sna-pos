-- 065: phone numbers kept as international digits so the same guest is found however the number is typed.
alter table public.countries add column if not exists dial_code text;
update public.countries set dial_code = v.d from (values ('IN','91'),('AE','971'),('MY','60'),('SG','65'),('ID','62'),('TH','66'),('PH','63')) v(c,d)
 where code = v.c and dial_code is null;
create or replace function app.clean_phone(p text) returns text
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare raw text := trim(coalesce(p, '')); d text; v_dial text;
begin
  d := regexp_replace(raw, '[^0-9]', '', 'g');
  if d = '' then return null; end if;
  if raw like '+%' then return d; end if;
  if d like '00%' then return substr(d, 3); end if;
  d := ltrim(d, '0');
  select c.dial_code into v_dial from public.restaurants r join public.countries c on c.code = r.country_code where r.id = app.current_restaurant_id();
  if length(d) <= 10 and v_dial is not null then return v_dial || d; end if;
  return d;
end $$;
revoke all on function app.clean_phone(text) from public, anon, authenticated;
