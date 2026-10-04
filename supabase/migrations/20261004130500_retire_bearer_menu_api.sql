-- Access now requires a signed-in account that belongs to the shared household.
revoke all on function public.get_shared_menu(uuid) from public, anon, authenticated;
revoke all on function public.save_shared_menu(uuid, jsonb) from public, anon, authenticated;
