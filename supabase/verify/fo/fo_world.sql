\set ON_ERROR_STOP on
-- An owner and a hotel, created through the real tenant-creation function, exactly as the console does.
insert into auth.users (id, email, encrypted_password)
values ('11111111-1111-1111-1111-111111111111', 'owner@fo.test',
        extensions.crypt('Test-Passw0rd!', extensions.gen_salt('bf')));
insert into auth.users (id, email, encrypted_password)
values ('22222222-2222-2222-2222-222222222222', 'cashier@fo.test',
        extensions.crypt('Test-Passw0rd!', extensions.gen_salt('bf')));

select set_config('request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', false);
select public.create_restaurant_with_owner(
  'Sunrise Hotels Pvt Ltd', 'Sunrise Residency', 'IN', 'Owner FO', 'Main', 'MN') as restaurant_id
\gset

-- A cashier with NO front office rights, to prove the rights actually bite.
insert into public.users (restaurant_id, auth_user_id, employee_code, full_name, role_id, email)
select :'restaurant_id', '22222222-2222-2222-2222-222222222222', 'EMP002', 'Cashier FO', r.id, 'cashier@fo.test'
  from public.roles r where r.restaurant_id = :'restaurant_id' and r.name = 'Cashier';
insert into public.user_branches (user_id, branch_id, restaurant_id)
select u.id, b.id, :'restaurant_id' from public.users u, public.branches b
 where u.auth_user_id = '22222222-2222-2222-2222-222222222222' and b.restaurant_id = :'restaurant_id';

select id as branch_id from public.branches where restaurant_id = :'restaurant_id' \gset
