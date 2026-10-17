-- The only persisted feature required by the foundation is the auth-linked profile.
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text check (display_name is null or (display_name = btrim(display_name) and char_length(display_name) between 1 and 100)),
  time_zone text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create function private.prepare_profile_update()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.time_zone is not null and not exists (
    select 1 from pg_catalog.pg_timezone_names where name = new.time_zone
  ) then
    raise exception 'Invalid time zone' using errcode = '23514';
  end if;
  new.updated_at := now();
  return new;
end;
$$;

create trigger profiles_before_update before update on public.profiles
for each row execute function private.prepare_profile_update();

create function private.create_profile()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id) values (new.id);
  return new;
end;
$$;

create trigger auth_user_created after insert on auth.users
for each row execute function private.create_profile();

-- Backfill existing accounts when applied to an already-used project.
insert into public.profiles (id)
select id from auth.users on conflict (id) do nothing;

alter table public.profiles enable row level security;
revoke all on public.profiles from anon, authenticated;
grant select on public.profiles to authenticated;
grant update (display_name, time_zone) on public.profiles to authenticated;

create policy profiles_select_own on public.profiles for select
to authenticated using ((select auth.uid()) = id);
create policy profiles_update_own on public.profiles for update
to authenticated using ((select auth.uid()) = id)
with check ((select auth.uid()) = id);

revoke all on function private.create_profile() from public, anon, authenticated;
revoke all on function private.prepare_profile_update() from public, anon, authenticated;

comment on table public.profiles is 'Private profile created by Auth. Account deletion explicitly removes its profile.';
comment on column public.profiles.time_zone is 'Nullable until explicitly chosen; do not infer a business timezone from the server.';
