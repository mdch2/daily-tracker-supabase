-- Migrations run as postgres. Require explicit access to application objects.
revoke create on schema public from public, anon, authenticated;
revoke all on schema private from public, anon, authenticated;

-- A schema-only REVOKE cannot remove PostgreSQL's global PUBLIC EXECUTE.
-- This affects future functions created by postgres, not existing extensions.
alter default privileges for role postgres
  revoke execute on functions from public, anon, authenticated, service_role;

alter default privileges for role postgres in schema public
  revoke all on tables from public, anon, authenticated, service_role;
alter default privileges for role postgres in schema public
  revoke all on sequences from public, anon, authenticated, service_role;
alter default privileges for role postgres in schema public
  revoke all on functions from public, anon, authenticated, service_role;

alter default privileges for role postgres in schema private
  revoke all on tables from public, anon, authenticated, service_role;
alter default privileges for role postgres in schema private
  revoke all on sequences from public, anon, authenticated, service_role;
alter default privileges for role postgres in schema private
  revoke all on functions from public, anon, authenticated, service_role;

-- Reconcile existing client grants, including privileges inherited from PUBLIC.
-- Revoking table privileges also removes corresponding column privileges.
alter table public.profiles enable row level security;
revoke all on table public.profiles from public, anon, authenticated;
grant select on table public.profiles to authenticated;
grant update (display_name, time_zone) on table public.profiles to authenticated;

alter policy profiles_select_own on public.profiles to authenticated
  using ((select auth.uid()) is not null and (select auth.uid()) = id);
alter policy profiles_update_own on public.profiles to authenticated
  using ((select auth.uid()) is not null and (select auth.uid()) = id)
  with check ((select auth.uid()) is not null and (select auth.uid()) = id);

-- Trigger functions are internal, never client-callable RPCs.
revoke all on function private.create_profile() from public, anon, authenticated, service_role;
revoke all on function private.prepare_profile_update() from public, anon, authenticated, service_role;
