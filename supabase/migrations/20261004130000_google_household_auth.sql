-- One shared menu space per Google account, with membership-scoped access.
create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated;

create table public.households (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) between 1 and 60),
  created_by uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
create table public.household_members (
  household_id uuid not null references public.households(id) on delete cascade,
  user_id uuid not null unique references auth.users(id) on delete cascade,
  role text not null default 'member' check (role in ('owner','member')),
  joined_at timestamptz not null default now(),
  primary key (household_id, user_id)
);
create table public.household_invites (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  invited_email text not null,
  invited_by uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  constraint household_invites_one_per_household unique (household_id),
  constraint household_invites_email_format check (position('@' in invited_email) > 1)
);
create table public.household_data (
  household_id uuid primary key references public.households(id) on delete cascade,
  data jsonb not null default '{"menu": {}, "shopping": []}'::jsonb,
  updated_at timestamptz not null default now(),
  updated_by uuid not null references auth.users(id),
  constraint household_data_is_object check (jsonb_typeof(data) = 'object')
);

alter table public.households enable row level security;
alter table public.household_members enable row level security;
alter table public.household_invites enable row level security;
alter table public.household_data enable row level security;
revoke all on public.households, public.household_members, public.household_invites, public.household_data from public, anon, authenticated;
grant select on public.households, public.household_members to authenticated;
grant select, insert, update on public.household_data to authenticated;

create or replace function private.is_household_member(p_household_id uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.household_members m
    where m.household_id = p_household_id and m.user_id = (select auth.uid())
  );
$$;
revoke all on function private.is_household_member(uuid) from public, anon;
grant execute on function private.is_household_member(uuid) to authenticated;

create policy "household members can read their household" on public.households
  for select to authenticated using (private.is_household_member(id));
create policy "household members can see household membership" on public.household_members
  for select to authenticated using (private.is_household_member(household_id));
create policy "members can read household data" on public.household_data
  for select to authenticated using (private.is_household_member(household_id));
create policy "members can add household data" on public.household_data
  for insert to authenticated with check (private.is_household_member(household_id) and updated_by = (select auth.uid()));
create policy "members can update household data" on public.household_data
  for update to authenticated using (private.is_household_member(household_id))
  with check (private.is_household_member(household_id) and updated_by = (select auth.uid()));

create or replace function public.create_household(p_name text)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare v_user_id uuid := auth.uid(); v_household_id uuid;
begin
  if v_user_id is null then raise exception 'Sign in is required'; end if;
  if p_name is null or length(trim(p_name)) not between 1 and 60 then raise exception 'Enter a name for the shared space'; end if;
  select household_id into v_household_id from public.household_members where user_id = v_user_id;
  if v_household_id is not null then return v_household_id; end if;
  insert into public.households (name, created_by) values (trim(p_name), v_user_id) returning id into v_household_id;
  insert into public.household_members (household_id, user_id, role) values (v_household_id, v_user_id, 'owner');
  insert into public.household_data (household_id, data, updated_by) values (v_household_id, '{"menu": {}, "shopping": []}'::jsonb, v_user_id);
  return v_household_id;
end;
$$;

create or replace function public.invite_household_email(p_invited_email text)
returns void language plpgsql security definer set search_path = ''
as $$
declare v_user_id uuid := auth.uid(); v_household_id uuid; v_email text := lower(trim(p_invited_email)); v_member_count integer;
begin
  if v_user_id is null then raise exception 'Sign in is required'; end if;
  if v_email is null or position('@' in v_email) < 2 then raise exception 'Enter a valid Google email'; end if;
  select household_id into v_household_id from public.household_members where user_id = v_user_id;
  if v_household_id is null then raise exception 'Create a shared space first'; end if;
  select count(*) into v_member_count from public.household_members where household_id = v_household_id;
  if v_member_count >= 2 then raise exception 'This shared space already has two members'; end if;
  if lower(coalesce((select email from auth.users where id = v_user_id), '')) = v_email then raise exception 'You cannot invite your own account'; end if;
  delete from public.household_invites where household_id = v_household_id;
  insert into public.household_invites (household_id, invited_email, invited_by) values (v_household_id, v_email, v_user_id);
end;
$$;

create or replace function public.accept_household_invitation()
returns uuid language plpgsql security definer set search_path = ''
as $$
declare v_user_id uuid := auth.uid(); v_email text; v_household_id uuid;
begin
  if v_user_id is null then raise exception 'Sign in is required'; end if;
  select household_id into v_household_id from public.household_members where user_id = v_user_id;
  if v_household_id is not null then return v_household_id; end if;
  select lower(email) into v_email from auth.users where id = v_user_id;
  if v_email is null then return null; end if;
  select household_id into v_household_id from public.household_invites
    where lower(invited_email) = v_email order by created_at desc limit 1;
  if v_household_id is null then return null; end if;
  if (select count(*) from public.household_members where household_id = v_household_id) >= 2 then raise exception 'This shared space already has two members'; end if;
  insert into public.household_members (household_id, user_id, role) values (v_household_id, v_user_id, 'member');
  delete from public.household_invites where household_id = v_household_id;
  return v_household_id;
end;
$$;

revoke all on function public.create_household(text) from public, anon, authenticated;
revoke all on function public.invite_household_email(text) from public, anon, authenticated;
revoke all on function public.accept_household_invitation() from public, anon, authenticated;
grant execute on function public.create_household(text) to authenticated;
grant execute on function public.invite_household_email(text) to authenticated;
grant execute on function public.accept_household_invitation() to authenticated;
do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'household_data') then
    alter publication supabase_realtime add table public.household_data;
  end if;
end;
$$;
