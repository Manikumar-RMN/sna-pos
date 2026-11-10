-- 215: User master details like Winsar: department, designation, employee no, relieving date.
-- A person whose relieving date has passed cannot sign in or act (checked in app.current_user_id and login_staff).
alter table public.users
  add column if not exists department text,
  add column if not exists designation text,
  add column if not exists employee_no text,
  add column if not exists relieving_date date;
-- (update_staff_details function and the two patched functions: see the applied migration "user_master_details")
