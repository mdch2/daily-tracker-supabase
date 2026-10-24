begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
insert into auth.users(id,email) values
 ('23000000-0000-4000-8000-000000000001','rename-owner@example.test'),
 ('23000000-0000-4000-8000-000000000002','rename-other@example.test');
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"23000000-0000-4000-8000-000000000001","role":"authenticated"}',true);
select public.initialize_habit_calendar('UTC',1::smallint);
select public.create_habit(md5('rename-habit')::uuid,'Original name','quantity','daily',null,null,20000,'pages');
select public.record_habit_day(md5('rename-record')::uuid,md5('rename-habit')::uuid,
 (clock_timestamp() at time zone 'UTC')::date,'add_amount',null,10000);
reset role;
create temp table before_rename as select h.updated_at, to_jsonb(d) as definition, to_jsonb(r) as record
 from public.habits h join public.habit_definitions d on d.habit_id=h.id
 join public.habit_day_records r on r.habit_id=h.id where h.id=md5('rename-habit')::uuid;
grant select on before_rename to authenticated;
create function pg_temp.rename(p_op text,p_name text,p_expected timestamptz)
returns jsonb language sql as $$ select public.rename_habit(md5(p_op)::uuid,md5('rename-habit')::uuid,p_name,p_expected) $$;
grant execute on function pg_temp.rename(text,text,timestamptz) to authenticated,anon;
select ok((select relrowsecurity from pg_class where oid='private.habit_edit_operations'::regclass),'Edit ledger has RLS');
select ok((select relrowsecurity from pg_class where oid='private.habit_creation_requests'::regclass),'Creation ledger has RLS');
select ok(not has_function_privilege('anon','public.rename_habit(uuid,uuid,text,timestamptz)','execute'),'Anonymous RPC denied');
select ok(not has_function_privilege('service_role','public.rename_habit(uuid,uuid,text,timestamptz)','execute'),'No service_role grant introduced');
set local role authenticated;
select set_config('request.jwt.claims','{"role":"authenticated"}',true);
select throws_ok($$select pg_temp.rename('missing-sub','No identity',now())$$,'HT001','unauthorized','JWT without sub rejected');
select set_config('request.jwt.claims','{"sub":"23000000-0000-4000-8000-000000000002","role":"authenticated"}',true);
select is((select count(*)::int from public.habits),0,'Other user cannot read name');
select throws_ok($$select pg_temp.rename('cross-owner','Stolen',now())$$,'HT004','not_found','Cannot rename another owner habit');
select set_config('request.jwt.claims','{"sub":"23000000-0000-4000-8000-000000000001","role":"authenticated"}',true);
select throws_ok($$update public.habits set name='Bypass'$$,'42501',null,'No direct UPDATE granted');
select throws_ok($$select * from private.habit_edit_operations$$,'42501',null,'Edit receipts private');
select throws_ok($$select * from private.habit_creation_requests$$,'42501',null,'Creation payload private');
select throws_ok($$select pg_temp.rename('empty','  ',(select updated_at from before_rename))$$,'HT003','invalid_input','Empty name rejected');
select throws_ok($$select pg_temp.rename('long',repeat('x',101),(select updated_at from before_rename))$$,'HT003','invalid_input','Long name rejected');
select throws_ok($$select pg_temp.rename('stale','Stale',(select updated_at-interval '1 second' from before_rename))$$,'HT008','revision_conflict','Stale name edit rejected');
select lives_ok($$select pg_temp.rename('rename-first','  New name  ',(select updated_at from before_rename))$$,'Owner renames with observed token');
select is((select name from public.habits where id=md5('rename-habit')::uuid),'New name','Name trimmed and persisted');
select ok((select updated_at > (select updated_at from before_rename) from public.habits where id=md5('rename-habit')::uuid),'Server advances token');
select is((select to_jsonb(d) from public.habit_definitions d where habit_id=md5('rename-habit')::uuid),(select definition from before_rename),'Definition unchanged');
select is((select to_jsonb(r) from public.habit_day_records r where habit_id=md5('rename-habit')::uuid),(select record from before_rename),'Historical record unchanged');
select lives_ok($$select public.create_habit(md5('rename-habit')::uuid,'Original name','quantity','daily',null,null,20000,'pages')$$,'Original creation retry still valid after rename');
select throws_ok($$select public.create_habit(md5('rename-habit')::uuid,'New name','quantity','daily',null,null,20000,'pages')$$,'HT005','operation_reused','Renamed metadata is not original creation payload');
select lives_ok($$select pg_temp.rename('rename-second','Latest',(select updated_at from public.habits where id=md5('rename-habit')::uuid))$$,'Later rename accepted');
select lives_ok($$select pg_temp.rename('rename-first','  New name  ',(select updated_at from before_rename))$$,'Uncertain first response can replay original receipt');
select is((select name from public.habits where id=md5('rename-habit')::uuid),'Latest','Old receipt never rolls back a later rename');
select throws_ok($$select pg_temp.rename('rename-first','Different',(select updated_at from before_rename))$$,'HT005','operation_reused','Operation payload cannot change');
select * from finish();
rollback;


