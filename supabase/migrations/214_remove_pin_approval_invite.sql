-- 214: sign-in is restaurant code + username + password only. Remove the PIN, manager-approval and invite-code functions.
drop function if exists public.approve_with_pin(text, text);
drop function if exists public.set_staff_pin(uuid, text);
drop function if exists public.clear_staff_pin(uuid);
drop function if exists public.create_pin_staff(text, uuid, text);
drop function if exists public.pin_unlock(text);
drop function if exists public.pin_lock();
drop function if exists public.pin_touch();
drop function if exists public.clear_pin_lockout(uuid);
drop function if exists public.invite_staff(text, text, uuid, text);
drop function if exists public.regenerate_invite(uuid);
drop function if exists public.cancel_invite(uuid);
drop function if exists public.claim_staff_invite(text);
drop function if exists app.new_invite_code();
drop function if exists app.pin_hash(uuid, text);
