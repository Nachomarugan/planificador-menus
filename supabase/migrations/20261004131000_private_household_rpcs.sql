-- Keep privileged database functions outside the exposed API schema.
alter function public.create_household(text) set schema private;
alter function public.invite_household_email(text) set schema private;
alter function public.accept_household_invitation() set schema private;

revoke all on function private.create_household(text) from public, anon, authenticated;
revoke all on function private.invite_household_email(text) from public, anon, authenticated;
revoke all on function private.accept_household_invitation() from public, anon, authenticated;
grant execute on function private.create_household(text) to authenticated;
grant execute on function private.invite_household_email(text) to authenticated;
grant execute on function private.accept_household_invitation() to authenticated;

create function public.create_household(p_name text)
returns uuid language sql security invoker set search_path = ''
as $$ select private.create_household(p_name); $$;
create function public.invite_household_email(p_invited_email text)
returns void language sql security invoker set search_path = ''
as $$ select private.invite_household_email(p_invited_email); $$;
create function public.accept_household_invitation()
returns uuid language sql security invoker set search_path = ''
as $$ select private.accept_household_invitation(); $$;

revoke all on function public.create_household(text) from public, anon, authenticated;
revoke all on function public.invite_household_email(text) from public, anon, authenticated;
revoke all on function public.accept_household_invitation() from public, anon, authenticated;
grant execute on function public.create_household(text) to authenticated;
grant execute on function public.invite_household_email(text) to authenticated;
grant execute on function public.accept_household_invitation() to authenticated;
