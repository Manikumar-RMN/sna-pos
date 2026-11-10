-- The User Master columns (department, designation, employee no, relieving date) were added without a
-- column-level SELECT grant. public.users is granted column by column, so every screen that read one of
-- them — the Users list and the User list report — failed and quietly showed an empty table.
grant select (department) on table public.users to authenticated, sna_pos_agent;
grant select (designation) on table public.users to authenticated, sna_pos_agent;
grant select (employee_no) on table public.users to authenticated, sna_pos_agent;
grant select (relieving_date) on table public.users to authenticated, sna_pos_agent;
