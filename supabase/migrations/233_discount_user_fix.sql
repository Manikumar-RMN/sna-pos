-- 233: item / category discount record the signed-in staff user (public.users.id), not the login id.
do $$ declare d text; begin
  d := pg_get_functiondef('public.set_item_discount(uuid,uuid,text,numeric,text)'::regprocedure);
  d := replace(d, 'v_user := auth.uid();', 'v_user := app.current_user_id();');
  execute d;
  d := pg_get_functiondef('public.set_category_discount(uuid,uuid,numeric,text)'::regprocedure);
  d := replace(d, 'v_user := auth.uid();', 'v_user := app.current_user_id();');
  execute d;
end $$;
