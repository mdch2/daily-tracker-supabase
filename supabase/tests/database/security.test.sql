begin;
create extension if not exists pgtap with schema extensions;
select plan(31);

select ok(not exists (
  select 1 from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind in ('r', 'p') and not c.relrowsecurity
    and not exists (
      select 1 from pg_depend d
      where d.classid = 'pg_class'::regclass and d.objid = c.oid and d.deptype = 'e'
    )
), 'Every exposed application table enforces RLS');

select ok(not has_schema_privilege(actor, 'public', 'CREATE'), actor || ' cannot create API objects')
from (values ('anon'), ('authenticated')) as roles(actor);
select ok(not has_schema_privilege(actor, 'private', 'USAGE,CREATE'), actor || ' cannot access the private schema')
from (values ('anon'), ('authenticated')) as roles(actor);

select ok(not has_function_privilege(actor, routine, 'EXECUTE'), actor || ' cannot execute ' || routine)
from (values ('anon'), ('authenticated'), ('service_role')) as roles(actor)
cross join (values ('private.create_profile()'), ('private.prepare_profile_update()')) as routines(routine);
select ok(not exists (
  select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'private' and not coalesce(p.proconfig @> array['search_path=""'], false)
), 'Internal functions pin an empty search_path');
select ok(
  (select prosecdef from pg_proc where oid = 'private.create_profile()'::regprocedure)
  and not (select prosecdef from pg_proc where oid = 'private.prepare_profile_update()'::regprocedure),
  'Only the Auth creation trigger needs definer privileges'
);

-- Deliberately omit GRANT and RLS on these disposable probes: even an object
-- awaiting its policies must be inaccessible by default. ROLLBACK removes it.
-- Test actual effective permissions, not only the default ACL catalog entries.
create table public.security_probe (id bigint generated always as identity primary key);
create table private.security_probe (id bigint generated always as identity primary key);
create function public.security_probe() returns integer
language sql security invoker set search_path = '' as $$ select 1 $$;
create function private.security_probe() returns integer
language sql security invoker set search_path = '' as $$ select 1 $$;

select ok(not has_table_privilege(actor, object_name, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN'),
  actor || ' has no automatic table privileges on ' || object_name)
from (values ('anon'), ('authenticated'), ('service_role')) as roles(actor)
cross join (values ('public.security_probe'), ('private.security_probe')) as objects(object_name);
select ok(not has_sequence_privilege(actor, pg_get_serial_sequence(object_name, 'id'), 'USAGE,SELECT,UPDATE'),
  actor || ' has no automatic sequence privileges on ' || object_name)
from (values ('anon'), ('authenticated'), ('service_role')) as roles(actor)
cross join (values ('public.security_probe'), ('private.security_probe')) as objects(object_name);
select ok(not has_function_privilege(actor, object_name, 'EXECUTE'),
  actor || ' has no automatic function privileges on ' || object_name)
from (values ('anon'), ('authenticated'), ('service_role')) as roles(actor)
cross join (values ('public.security_probe()'), ('private.security_probe()')) as objects(object_name);

select * from finish();
rollback;
