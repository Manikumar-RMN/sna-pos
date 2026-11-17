-- When a bill is paid (or refunded) its kitchen tickets are finished: mark them served so the dashboard, the Kitchen screen
-- and the Day close warning all count the same open tickets. Voiding already cancels them.
create or replace function app.trg_close_tickets_when_paid()
returns trigger language plpgsql security definer set search_path to 'public','pg_temp' as $$
begin
  if new.payment_status in ('paid','partially_refunded','refunded') and old.payment_status is distinct from new.payment_status then
    update public.kitchen_tickets set status = 'served'
     where order_id = new.id and status in ('new','preparing','ready');
  end if;
  return new;
end $$;

drop trigger if exists trg_close_tickets_when_paid on public.orders;
create trigger trg_close_tickets_when_paid after update of payment_status on public.orders
  for each row execute function app.trg_close_tickets_when_paid();

-- Tickets already left open on bills that are paid.
update public.kitchen_tickets k set status = 'served'
  from public.orders o
 where o.id = k.order_id and o.payment_status in ('paid','partially_refunded','refunded') and k.status in ('new','preparing','ready');
