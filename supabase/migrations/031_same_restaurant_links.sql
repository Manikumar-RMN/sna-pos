-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260927111057, name '31_same_restaurant_links'. This is the SQL that actually ran.

alter table public.agent_sessions add constraint agent_sessions_rest_id_uq unique (restaurant_id, id);
alter table public.branches add constraint branches_rest_id_uq unique (restaurant_id, id);
alter table public.categories add constraint categories_rest_id_uq unique (restaurant_id, id);
alter table public.customers add constraint customers_rest_id_uq unique (restaurant_id, id);
alter table public.devices add constraint devices_rest_id_uq unique (restaurant_id, id);
alter table public.dining_tables add constraint dining_tables_rest_id_uq unique (restaurant_id, id);
alter table public.floors add constraint floors_rest_id_uq unique (restaurant_id, id);
alter table public.modifier_groups add constraint modifier_groups_rest_id_uq unique (restaurant_id, id);
alter table public.modifier_items add constraint modifier_items_rest_id_uq unique (restaurant_id, id);
alter table public.payment_methods add constraint payment_methods_rest_id_uq unique (restaurant_id, id);
alter table public.products add constraint products_rest_id_uq unique (restaurant_id, id);
alter table public.roles add constraint roles_rest_id_uq unique (restaurant_id, id);
alter table public.tax_groups add constraint tax_groups_rest_id_uq unique (restaurant_id, id);
alter table public.tax_rates add constraint tax_rates_rest_id_uq unique (restaurant_id, id);
alter table public.users add constraint users_rest_id_uq unique (restaurant_id, id);
alter table public.agent_actions add constraint agent_actions_session_id_same_rest foreign key (restaurant_id, session_id) references public.agent_sessions(restaurant_id, id);
alter table public.agent_actions add constraint agent_actions_reviewed_by_same_rest foreign key (restaurant_id, reviewed_by) references public.users(restaurant_id, id);
alter table public.agent_messages add constraint agent_messages_session_id_same_rest foreign key (restaurant_id, session_id) references public.agent_sessions(restaurant_id, id);
alter table public.agent_sessions add constraint agent_sessions_user_id_same_rest foreign key (restaurant_id, user_id) references public.users(restaurant_id, id);
alter table public.agent_sessions add constraint agent_sessions_branch_id_same_rest foreign key (restaurant_id, branch_id) references public.branches(restaurant_id, id);
alter table public.branch_settings add constraint branch_settings_branch_id_same_rest foreign key (restaurant_id, branch_id) references public.branches(restaurant_id, id);
alter table public.dining_tables add constraint dining_tables_branch_id_same_rest foreign key (restaurant_id, branch_id) references public.branches(restaurant_id, id);
alter table public.dining_tables add constraint dining_tables_floor_id_same_rest foreign key (restaurant_id, floor_id) references public.floors(restaurant_id, id);
alter table public.floors add constraint floors_branch_id_same_rest foreign key (restaurant_id, branch_id) references public.branches(restaurant_id, id);
alter table public.modifier_items add constraint modifier_items_modifier_group_id_same_rest foreign key (restaurant_id, modifier_group_id) references public.modifier_groups(restaurant_id, id);
alter table public.printers add constraint printers_branch_id_same_rest foreign key (restaurant_id, branch_id) references public.branches(restaurant_id, id);
alter table public.product_modifier_groups add constraint product_modifier_groups_product_id_same_rest foreign key (restaurant_id, product_id) references public.products(restaurant_id, id);
alter table public.product_modifier_groups add constraint product_modifier_groups_modifier_group_id_same_rest foreign key (restaurant_id, modifier_group_id) references public.modifier_groups(restaurant_id, id);
alter table public.products add constraint products_category_id_same_rest foreign key (restaurant_id, category_id) references public.categories(restaurant_id, id);
alter table public.products add constraint products_tax_group_id_same_rest foreign key (restaurant_id, tax_group_id) references public.tax_groups(restaurant_id, id);
alter table public.sync_log add constraint sync_log_device_id_same_rest foreign key (restaurant_id, device_id) references public.devices(restaurant_id, id);
alter table public.tax_rate_components add constraint tax_rate_components_tax_rate_id_same_rest foreign key (restaurant_id, tax_rate_id) references public.tax_rates(restaurant_id, id);
alter table public.tax_rates add constraint tax_rates_tax_group_id_same_rest foreign key (restaurant_id, tax_group_id) references public.tax_groups(restaurant_id, id);
alter table public.order_items add constraint order_items_product_id_same_rest foreign key (restaurant_id, product_id) references public.products(restaurant_id, id);
alter table public.order_item_modifiers add constraint order_item_modifiers_modifier_item_id_same_rest foreign key (restaurant_id, modifier_item_id) references public.modifier_items(restaurant_id, id);
alter table public.orders add constraint orders_dining_table_id_same_rest foreign key (restaurant_id, dining_table_id) references public.dining_tables(restaurant_id, id);
alter table public.orders add constraint orders_customer_id_same_rest foreign key (restaurant_id, customer_id) references public.customers(restaurant_id, id);
alter table public.payments add constraint payments_payment_method_id_same_rest foreign key (restaurant_id, payment_method_id) references public.payment_methods(restaurant_id, id);
alter table public.users add constraint users_role_id_same_rest foreign key (restaurant_id, role_id) references public.roles(restaurant_id, id);

revoke execute on function public.add_order_items, public.cancel_order_item, public.merge_orders,
  public.move_order_table, public.split_order, public.clear_pin_lockout, public.pin_touch from public, anon;
grant execute on function public.add_order_items, public.cancel_order_item, public.merge_orders,
  public.move_order_table, public.split_order, public.clear_pin_lockout, public.pin_touch to authenticated;
alter default privileges in schema public revoke execute on functions from public;
alter default privileges in schema public revoke execute on functions from anon;
