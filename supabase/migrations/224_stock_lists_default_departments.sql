-- Restaurants whose department list was started from past use get the standard departments too, so Bar, Bakery and the rest are not refused.
insert into public.stock_lists (restaurant_id, kind, name)
select r.restaurant_id, 'department', d
  from (select distinct restaurant_id from public.stock_lists where kind = 'department') r
  cross join unnest(array['Kitchen', 'Bar', 'Bakery', 'Housekeeping', 'Other']) d
on conflict do nothing;
