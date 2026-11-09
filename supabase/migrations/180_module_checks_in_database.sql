-- 180: the database now refuses what a client has not bought.
-- Until now POS, Reports and MIS, stock batches and QR ordering were hidden on screen only.
-- Each function below gets a first line that checks the module (app.require_feature), so a
-- restaurant without it is refused even if someone calls the database directly.
--   pos          billing, payments, refunds, kitchen, shifts, day close, customers, pre-orders, deliveries
--   reports_mis  every report, the GST register, the sales and settlement reports, report e-mails
--   stock        product batches
--   qr_ordering  the guest QR menu and QR order (these two are public, so they check the table's restaurant)

do $$
declare
  spec jsonb := jsonb_build_object(
    'pos', jsonb_build_array(
      'account_charge','account_save','account_settle','account_statement','accounts_list',
      'add_order_items','adjust_order','attach_customer','cancel_order_item','change_payment_method',
      'claim_tickets_for_print','close_day','close_shift','create_order','current_shift',
      'customer_detail','customer_favourites','customer_list','day_report','day_status',
      'deliveries_list','delivery_update','floor_status','issue_credit_note',
      'kot_cancel','kot_cancel_item','kot_kitchen_seen','kot_modify_item','log_print','make_complimentary',
      'mark_tickets_printed','move_order_items','move_order_table',
      'online_order_accept','online_order_callback','online_order_mark_ready','online_order_reject','online_orders_list',
      'open_shift','pay_order','pre_order_advance','pre_order_bill','pre_order_cancel','pre_order_save','pre_orders_list',
      'quote_order','record_cash_movement','refund_order','reject_qr_order','reopen_day','rider_save','rider_settle',
      'send_to_kitchen','set_bill_customer','set_kitchen_status','set_order_guest','shift_report','split_order',
      'sync_offline_bill','void_order','waiter_ready_alerts','waiter_ready_seen'),
    'reports_mis', jsonb_build_array(
      'report_bills_detail','report_covers','report_customers','report_discounts','report_leakage','report_pending_bills',
      'report_pending_kot','report_popular_items','report_reasons_summary','report_reprints','report_sales_day_book',
      'report_sales_month_book','report_settlement','report_table_turnaround','report_tax','report_tips','report_unsold_items',
      'report_void_bills','report_waiter_sales','gst_register','sales_report','settlement_report','session_report',
      'chain_report','send_report_now','remove_report_schedule','set_report_schedule_active'),
    'stock', jsonb_build_array('batch_add','batch_stock','batch_write_off','batches_list')
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

-- QR ordering (public functions): check the restaurant that owns the table
do $$
declare def text; newdef text; oid_ oid;
begin
  for oid_ in select p.oid from pg_proc p join pg_namespace s on s.oid = p.pronamespace
               where s.nspname = 'public' and p.proname in ('qr_menu', 'qr_place_order') loop
    def := pg_get_functiondef(oid_);
    if def like '%qr_ordering%' then continue; end if;
    newdef := regexp_replace(def, E'\\mbegin\\s*\\n',
      E'begin\n  if not app.feature_on(t.restaurant_id, ''qr_ordering'') then raise exception ''QR ordering is not available at this restaurant.''; end if;\n', '');
    if newdef = def then raise exception 'Could not patch qr function'; end if;
    execute newdef;
  end loop;
end $$;
