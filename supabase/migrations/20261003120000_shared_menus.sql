-- Shared menu storage accessed only through capability-link RPC functions.
-- Anyone holding a generated share UUID can read and edit that menu.

create table if not exists public.shared_menus (
  id uuid primary key,
  data jsonb not null default '{"menu": {}, "shopping": []}'::jsonb,
  updated_at timestamptz not null default now(),
  constraint shared_menus_data_is_object check (jsonb_typeof(data) = 'object')
);

alter table public.shared_menus enable row level security;
revoke all on table public.shared_menus from public, anon, authenticated;

create or replace function public.get_shared_menu(p_share_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object('state', m.data, 'updated_at', m.updated_at)
  from public.shared_menus as m
  where m.id = p_share_id;
$$;

create or replace function public.save_shared_menu(p_share_id uuid, p_state jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  saved public.shared_menus;
begin
  if p_share_id is null then
    raise exception 'A share id is required';
  end if;
  if p_state is null or jsonb_typeof(p_state) <> 'object' then
    raise exception 'State must be a JSON object';
  end if;
  if pg_column_size(p_state) > 65536 then
    raise exception 'State is too large';
  end if;

  insert into public.shared_menus (id, data, updated_at)
  values (p_share_id, p_state, now())
  on conflict (id) do update
    set data = excluded.data,
        updated_at = now()
  returning * into saved;

  return jsonb_build_object('state', saved.data, 'updated_at', saved.updated_at);
end;
$$;

revoke all on function public.get_shared_menu(uuid) from public, anon, authenticated;
revoke all on function public.save_shared_menu(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.get_shared_menu(uuid) to anon;
grant execute on function public.save_shared_menu(uuid, jsonb) to anon;
