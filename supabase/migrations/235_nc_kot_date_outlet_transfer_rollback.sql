-- Undo 235: the three Winsar Options functions go; nothing else is touched (no table or column was changed).
drop function if exists public.undo_complimentary(uuid, text);
drop function if exists public.kot_date_transfer(uuid, date, text);
drop function if exists public.order_outlet_transfer(uuid, uuid, uuid, text);
