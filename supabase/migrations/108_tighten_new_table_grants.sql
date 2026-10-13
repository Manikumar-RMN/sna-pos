-- 108: The four tables added in 102-107 are read-only for signed-in users, as tested.
-- (Supabase gives new tables full rights by default; row-level security already blocked writes, this makes it explicit.)
revoke all on public.brands, public.riders, public.liquor_series, public.online_orders from anon, authenticated;
grant select on public.brands, public.riders, public.liquor_series, public.online_orders to authenticated;
