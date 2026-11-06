begin;
create extension if not exists pgtap with schema extensions;
-- Test harness only: new extension functions also follow the denied defaults.
-- Grant only pgTAP routines, never application routines. ROLLBACK removes this.
do $$
declare routine record;
begin
  for routine in
    select p.oid::regprocedure as signature from pg_proc p
    join pg_depend d on d.classid = 'pg_proc'::regclass and d.objid = p.oid and d.deptype = 'e'
    join pg_extension e on e.oid = d.refobjid where e.extname = 'pgtap'
  loop
    execute format('grant execute on function %s to anon, authenticated', routine.signature);
  end loop;
end;
$$;
select plan(35);

insert into auth.users (id, email, raw_user_meta_data) values
  ('10000000-0000-4000-8000-000000000001', 'owner@example.test', '{"role":"service_role","is_admin":true}'),
  ('10000000-0000-4000-8000-000000000002', 'other@example.test', '{}');

select is((select count(*)::integer from public.profiles where id in (
  '10000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000002'
)), 2, 'Auth creates profiles atomically');
select ok((select relrowsecurity from pg_class where oid = 'public.profiles'::regclass), 'Profiles enforce RLS');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"10000000-0000-4000-8000-000000000001","role":"authenticated","user_metadata":{"role":"service_role","is_admin":true,"sub":"10000000-0000-4000-8000-000000000002"}}', true);
select is((select count(*)::integer from public.profiles), 1, 'Editable metadata does not expand owner access');
select is((select id from public.profiles), '10000000-0000-4000-8000-000000000001'::uuid, 'Owner reads their own profile');
select is((select count(*)::integer from public.profiles where id = '10000000-0000-4000-8000-000000000002'), 0, 'Other user is invisible');
select lives_ok($$update public.profiles set display_name = 'Synthetic user' where id = '10000000-0000-4000-8000-000000000001'$$, 'Owner updates permitted fields');
select lives_ok($$select public.initialize_habit_calendar('America/Bogota',1::smallint)$$, 'Owner initializes business calendar');
select is((select display_name from public.profiles), 'Synthetic user', 'Update persists');
with changed as (
  update public.profiles set display_name = 'Intrusion' where id = '10000000-0000-4000-8000-000000000002' returning id
) select is((select count(*)::integer from changed), 0, 'Cross-user update changes no rows');
select throws_ok($$insert into public.profiles (id) values ('10000000-0000-4000-8000-000000000001')$$, '42501', null, 'Client cannot insert profiles');
select throws_ok($$delete from public.profiles$$, '42501', null, 'Client cannot delete profiles');
select throws_ok($$truncate public.profiles$$, '42501', null, 'Client cannot truncate profiles');
select throws_ok($$update public.profiles set id = '10000000-0000-4000-8000-000000000002'$$, '42501', null, 'Owner cannot transfer ownership');
select throws_ok($$update public.profiles set created_at = now()$$, '42501', null, 'Client cannot rewrite creation timestamp');
select throws_ok($$update public.profiles set updated_at = now()$$, '42501', null, 'Client cannot rewrite update timestamp');
select throws_ok($$update public.profiles set time_zone = 'Invalid/Timezone'$$, '42501', null, 'Timezone writes require calendar RPC');
select is((select time_zone from public.profiles), 'America/Bogota', 'Rejected write preserves the previous timezone');

select set_config('request.jwt.claims', '{"sub":"10000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
select is((select id from public.profiles), '10000000-0000-4000-8000-000000000002'::uuid, 'Second user reads only their own profile');
select lives_ok($$update public.profiles set display_name = 'Second synthetic user'$$, 'Second user can update their own profile');
with changed as (
  update public.profiles set display_name = 'Intrusion' where id = '10000000-0000-4000-8000-000000000001' returning id
) select is((select count(*)::integer from changed), 0, 'Isolation also blocks reverse cross-user updates');

-- A client role without a subject must never read or write private rows.
select set_config('request.jwt.claims', '{}', true);
select is((select count(*)::integer from public.profiles), 0, 'Missing subject sees no profiles');
with changed as (
  update public.profiles set display_name = 'Intrusion' returning id
) select is((select count(*)::integer from changed), 0, 'Missing subject updates no profiles');
select set_config('request.jwt.claims', '{"sub":"10000000-0000-4000-8000-000000000099","role":"authenticated"}', true);
select is((select count(*)::integer from public.profiles), 0, 'Unknown subject sees no profiles');
with changed as (
  update public.profiles set display_name = 'Intrusion' returning id
) select is((select count(*)::integer from changed), 0, 'Unknown subject updates no profiles');

reset role;
set local role anon;
select set_config('request.jwt.claims', '{}', true);
select throws_ok($$select * from public.profiles$$, '42501', null, 'Anonymous cannot read');
select throws_ok($$insert into public.profiles (id) values ('10000000-0000-4000-8000-000000000099')$$, '42501', null, 'Anonymous cannot insert');
select throws_ok($$update public.profiles set display_name = 'Intrusion'$$, '42501', null, 'Anonymous cannot update');
select throws_ok($$delete from public.profiles$$, '42501', null, 'Anonymous cannot delete');
select set_config('request.jwt.claims', '{"sub":"10000000-0000-4000-8000-000000000001","role":"anon"}', true);
select throws_ok($$select * from public.profiles$$, '42501', null, 'Subject alone does not authorize the anonymous role');
reset role;

select is((select display_name from public.profiles where id = '10000000-0000-4000-8000-000000000001'), 'Synthetic user', 'Owner profile survives all denied writes');
select is((select display_name from public.profiles where id = '10000000-0000-4000-8000-000000000002'), 'Second synthetic user', 'Other profile only reflects its owner write');

-- Check trigger creation and the documented account-deletion cascade.
select lives_ok($$insert into auth.users (id, email) values ('10000000-0000-4000-8000-000000000003', 'auth-trigger@example.test')$$, 'Account creation still runs the internal trigger');
select is((select count(*)::integer from public.profiles where id = '10000000-0000-4000-8000-000000000003'), 1, 'Auth trigger still creates the profile');
select lives_ok($$delete from auth.users where id = '10000000-0000-4000-8000-000000000003'$$, 'Administrative Auth deletion remains available');
select is((select count(*)::integer from public.profiles where id = '10000000-0000-4000-8000-000000000003'), 0, 'Account deletion removes its linked profile');

select * from finish();
rollback;
