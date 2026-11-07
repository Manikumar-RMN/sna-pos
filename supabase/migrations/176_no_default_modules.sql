-- 176: A new client starts with NO modules. The sales team switches on what the client bought (sna_set_module, SNA console).
-- Undoes the default grant added in 175. Restaurants that already exist keep the rows 175 gave them.
-- Safe to run again.
drop trigger if exists trg_default_modules on public.restaurants;
drop function if exists app.trg_default_modules();
