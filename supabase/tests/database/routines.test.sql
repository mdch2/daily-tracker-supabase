begin;
create extension if not exists pgtap with schema extensions;
do $$ declare f record; begin
 for f in select p.oid::regprocedure as signature from pg_proc p join pg_depend d on d.classid='pg_proc'::regclass
   and d.objid=p.oid and d.deptype='e' join pg_extension e on e.oid=d.refobjid where e.extname='pgtap'
 loop execute format('grant execute on function %s to anon,authenticated',f.signature); end loop;
end $$;
select no_plan();
insert into auth.users(id,email) values
 ('27000000-0000-4000-8000-000000000001','routine-a@example.test'),
 ('27000000-0000-4000-8000-000000000002','routine-b@example.test');
create function pg_temp.rtoday() returns date language sql as $$select (clock_timestamp() at time zone 'UTC')::date$$;
create function pg_temp.own(p_key text,p_required boolean default true) returns jsonb language sql as $$
 select jsonb_build_object('id',md5(p_key)::uuid,'kind','own','title',p_key,'habit_id',null,'required',p_required) $$;
create function pg_temp.link(p_key text,p_habit text,p_required boolean default true) returns jsonb language sql as $$
 select jsonb_build_object('id',md5(p_key)::uuid,'kind','habit','title',null,'habit_id',md5(p_habit)::uuid,'required',p_required) $$;
create function pg_temp.make_r(p_key text,p_steps jsonb) returns uuid language sql as $$
 select public.create_routine(md5(p_key)::uuid,p_key,'daily',p_steps) $$;
create function pg_temp.record_r(p_op text,p_routine text,p_step text,p_done boolean,p_rev bigint,p_days int default 0)
returns jsonb language sql as $$
 select public.record_routine_step(md5(p_op)::uuid,md5(p_routine)::uuid,md5(p_step)::uuid,pg_temp.rtoday()+p_days,p_done,p_rev) $$;
create function pg_temp.edit_r(p_op text,p_routine text,p_name text,p_steps jsonb) returns jsonb language sql as $$
 select public.edit_routine(md5(p_op)::uuid,md5(p_routine)::uuid,p_name,
   (select updated_at from public.routines where id=md5(p_routine)::uuid),'daily',p_steps) $$;
grant execute on function pg_temp.rtoday(),pg_temp.own(text,boolean),pg_temp.link(text,text,boolean),
 pg_temp.make_r(text,jsonb),pg_temp.record_r(text,text,text,boolean,bigint,int),pg_temp.edit_r(text,text,text,jsonb) to authenticated,anon;
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"27000000-0000-4000-8000-000000000001","role":"authenticated"}',true);
select throws_ok($$select pg_temp.make_r('early-r',jsonb_build_array(pg_temp.own('early-step')))$$,'RT002','calendar_required','Calendar required');
select public.initialize_habit_calendar('UTC',1::smallint);
select public.create_habit(md5('rhabit')::uuid,'Linked habit','quantity','daily',null,null,20000,'pages');
select public.create_habit(md5('rflex')::uuid,'Flexible habit','binary','weekly',null,3::smallint);
select lives_ok($$select pg_temp.make_r('routine-main',jsonb_build_array(pg_temp.own('first'),pg_temp.link('linked','rhabit'),pg_temp.own('optional',false)))$$,'Mixed routine created');
select is((select start_date from public.routines where id=md5('routine-main')::uuid),pg_temp.rtoday(),'Start uses server date');
select is((select count(*)::int from public.routine_steps),3,'Three stable steps');
select is((select count(*)::int from public.routine_step_day_records),0,'No invented completions');
select is((public.get_routines()->'routines'->0->'definitions'->0->'steps'->0->>'title'),'first','Read preserves step order');
select lives_ok($$select pg_temp.make_r('routine-main',jsonb_build_array(pg_temp.own('first'),pg_temp.link('linked','rhabit'),pg_temp.own('optional',false)))$$,'Create retry idempotent');
select throws_ok($$select pg_temp.make_r('routine-main',jsonb_build_array(pg_temp.own('other')))$$,'RT005','operation_reused','Creation payload fixed');
select is((select count(*)::int from public.routines),1,'No duplicate entity');
select throws_ok($$select pg_temp.make_r('bad-empty','[]'::jsonb)$$,'RT003','invalid_input','No empty routine');
select throws_ok($$select pg_temp.make_r('bad-optional',jsonb_build_array(pg_temp.own('o-only',false)))$$,'RT003','invalid_input','At least one required step');
select throws_ok($$select pg_temp.make_r('bad-name',jsonb_build_array(pg_temp.own('')))$$,'RT003','invalid_input','Empty own label rejected');
select throws_ok($$select pg_temp.make_r('bad-duplicate',jsonb_build_array(pg_temp.own('dup'),pg_temp.own('dup')))$$,'RT003','invalid_input','Duplicate step identity rejected');
select throws_ok($$select pg_temp.make_r('bad-linkdup',jsonb_build_array(pg_temp.link('dup-a','rhabit'),pg_temp.link('dup-b','rhabit')))$$,'RT003','invalid_input','Habit not repeated in one routine');
select throws_ok($$select pg_temp.make_r('bad-flex',jsonb_build_array(pg_temp.link('flex-required','rflex')))$$,'RT011','flexible_optional','Flexible habit cannot become daily obligation');
select lives_ok($$select pg_temp.make_r('routine-flex',jsonb_build_array(pg_temp.own('flex-own'),pg_temp.link('flex-optional','rflex',false)))$$,'Flexible optional accepted');
select throws_ok($$select public.create_routine(md5('bad-mask')::uuid,'bad-mask','weekdays',jsonb_build_array(pg_temp.own('mask-own')),0::smallint)$$,'RT003','invalid_input','Empty weekdays rejected');
select throws_ok($$select public.create_routine(md5('bad-type')::uuid,'bad-type','weekly',jsonb_build_array(pg_temp.own('type-own')))$$,'RT003','invalid_input','No weekly flexible routine');
select throws_ok($$select public.create_routine(md5('bad-json')::uuid,'bad-json','daily','[{"id":"not-uuid","kind":"own","title":"x","required":true}]')$$,'RT003','invalid_input','Malformed UUID maps to safe error');
select throws_ok($$select public.create_routine(md5('bad-many')::uuid,'bad-many','daily',(select jsonb_agg(pg_temp.own('many-'||n)) from generate_series(1,31) n))$$,'RT003','invalid_input','Maximum 30 steps');
select is((pg_temp.record_r('r-op1','routine-main','first',true,0)->>'revision')::int,1,'First own completion confirmed');
select is((pg_temp.record_r('r-op1','routine-main','first',true,0)->>'revision')::int,1,'Replay does not increment');
select throws_ok($$select pg_temp.record_r('r-op1','routine-main','first',false,1)$$,'RT005','operation_reused','Reused operation content rejected');
select throws_ok($$select pg_temp.record_r('r-stale','routine-main','first',false,0)$$,'RT008','revision_conflict','Stale own correction rejected');
select lives_ok($$select pg_temp.record_r('r-op2','routine-main','first',false,1)$$,'Own completion can be reversed');
select is((select completed from public.routine_step_day_records where step_id=md5('first')::uuid),false,'False distinct from absence');
select throws_ok($$select pg_temp.record_r('r-yesterday','routine-main','first',true,2,-1)$$,'RT006','outside_window','Yesterday read-only');
select throws_ok($$select pg_temp.record_r('r-tomorrow','routine-main','first',true,2,1)$$,'RT006','outside_window','Tomorrow read-only');
select throws_ok($$select pg_temp.record_r('r-linked','routine-main','linked',true,0)$$,'RT007','ineligible_date','Cannot copy linked completion into routine record');
select lives_ok($$select public.record_habit_day(md5('r-habit-write')::uuid,md5('rhabit')::uuid,pg_temp.rtoday(),'add_amount',null,20000)$$,'Habit uses existing command');
select is((select count(*)::int from public.habit_day_records where habit_id=md5('rhabit')::uuid),1,'Habit has one source record');
select is((select count(*)::int from public.routine_step_day_records),1,'Linked write creates no own record');
select throws_ok($$insert into public.routines(id,user_id,name,start_date) values(gen_random_uuid(),auth.uid(),'bypass',pg_temp.rtoday())$$,'42501',null,'Direct INSERT denied');
select throws_ok($$update public.routines set name='bypass'$$,'42501',null,'Direct UPDATE denied');
select throws_ok($$delete from public.routines$$,'42501',null,'Direct DELETE denied');
select throws_ok($$update public.routines set user_id=gen_random_uuid()$$,'42501',null,'Owner transfer denied');
select throws_ok($$update public.routines set updated_at=now()$$,'42501',null,'Timestamp write denied');
select throws_ok($$update public.routine_definitions set weekday_mask=1$$,'42501',null,'Definition DML denied');
select throws_ok($$insert into public.routine_step_day_records select * from public.routine_step_day_records$$,'42501',null,'Record INSERT denied');
select throws_ok($$update public.routine_step_day_records set completed=true$$,'42501',null,'Record UPDATE denied');
select throws_ok($$delete from public.routine_steps$$,'42501',null,'Step DELETE denied');
select throws_ok($$select * from private.routine_operations$$,'42501',null,'Receipts inaccessible');
select throws_ok($$select private.normalize_routine_steps('[]')$$,'42501',null,'Helper inaccessible');
select is((pg_temp.edit_r('r-edit','routine-main','Renamed',jsonb_build_array(pg_temp.own('first'),pg_temp.own('new-next')))->>'effective_from')::date,
 pg_temp.rtoday()-((extract(isodow from pg_temp.rtoday())::int-1+7)%7)+7,'Structure effective next week');
select is((select name from public.routines where id=md5('routine-main')::uuid),'Renamed','Name immediate');
select is((select count(*)::int from public.routine_definitions where routine_id=md5('routine-main')::uuid),2,'Historical definition preserved');
select is((select count(*)::int from public.routine_definition_steps ds join public.routine_definitions d on d.id=ds.definition_id
 where d.routine_id=md5('routine-main')::uuid and d.effective_from=pg_temp.rtoday()),3,'Current steps unchanged');
select throws_ok($$select pg_temp.record_r('r-not-yet','routine-main','new-next',true,0)$$,'RT007','ineligible_date','Future step not writable today');
select lives_ok($$select pg_temp.edit_r('r-replace','routine-main','Renamed',jsonb_build_array(pg_temp.own('first'),pg_temp.own('next-replacement')))$$,'Future definition replaceable');
select is((select count(*)::int from public.routine_definitions where routine_id=md5('routine-main')::uuid),2,'No duplicate pending definition');
select lives_ok($$select public.edit_routine(md5('r-name')::uuid,md5('routine-main')::uuid,'Name only',
 (select updated_at from public.routines where id=md5('routine-main')::uuid))$$,'Name-only edit accepted');
select is((select count(*)::int from public.routine_definitions where routine_id=md5('routine-main')::uuid),2,'Name-only creates no definition');
select throws_ok($$select public.edit_routine(md5('r-old-token')::uuid,md5('routine-main')::uuid,'Conflict','2000-01-01Z'::timestamptz)$$,
 'RT008','revision_conflict','Metadata conflict detected');
select throws_ok($$select public.get_routines(null,-1)$$,'RT003','invalid_input','Read offset validated');

-- A second owner cannot observe or link another account's entities.
select set_config('request.jwt.claims','{"sub":"27000000-0000-4000-8000-000000000002","role":"authenticated"}',true);
select public.initialize_habit_calendar('UTC',7::smallint);
select is((select count(*)::int from public.routines),0,'B cannot read A routines');
select is((select count(*)::int from public.routine_definitions),0,'B cannot read A definitions');
select is((select count(*)::int from public.routine_steps),0,'B cannot read A identities');
select is((select count(*)::int from public.routine_definition_steps),0,'B cannot read A memberships');
select is((select count(*)::int from public.routine_step_day_records),0,'B cannot read A records');
select is(jsonb_array_length(public.get_routines(array[md5('routine-main')::uuid])->'routines'),0,'Read RPC respects RLS');
select throws_ok($$select pg_temp.record_r('cross-record','routine-main','first',true,2)$$,'RT004','not_found','Cross record denied');
select throws_ok($$select public.edit_routine(md5('cross-edit')::uuid,md5('routine-main')::uuid,'Cross',clock_timestamp())$$,'RT004','not_found','Cross edit denied');
select throws_ok($$select public.archive_routine(md5('cross-archive')::uuid,md5('routine-main')::uuid,clock_timestamp())$$,'RT004','not_found','Cross archive denied');
select throws_ok($$select pg_temp.make_r('cross-link',jsonb_build_array(pg_temp.own('cross-own'),pg_temp.link('cross-linked','rhabit')))$$,'RT004','not_found','Cross-tenant habit link denied');
select lives_ok($$select pg_temp.make_r('routine-b',jsonb_build_array(pg_temp.own('b-step')))$$,'B can create own');
select is((select count(*)::int from public.routines),1,'B only sees own routine');
select set_config('request.jwt.claims','{"sub":"27000000-0000-4000-8000-000000000001","role":"authenticated"}',true);
select is((select count(*)::int from public.routines),2,'A cannot read B routine');
select lives_ok($$select public.archive_routine(md5('r-archive')::uuid,md5('routine-main')::uuid,
 (select updated_at from public.routines where id=md5('routine-main')::uuid))$$,'Archive preserves entity');
select is((select count(*)::int from public.routine_step_day_records),1,'Archive preserves history');
select is(jsonb_array_length(public.get_routines()->'routines'),1,'Active listing excludes archive');
select is(jsonb_array_length(public.get_routines(null,0,true)->'routines'),1,'Archived listing available');
select is(jsonb_array_length(public.get_routines(array[md5('routine-main')::uuid])->'routines'),1,'Archived detail remains readable');
select throws_ok($$select pg_temp.record_r('r-archived-write','routine-main','first',true,2)$$,'RT009','archived','Archived own write denied');
select is((pg_temp.record_r('r-op1','routine-main','first',true,0)->>'revision')::int,1,'Old replay recognized after archive');
select is((select completed from public.routine_step_day_records where step_id=md5('first')::uuid),false,'Old receipt does not roll back state');
select throws_ok($$select pg_temp.edit_r('r-archived-edit','routine-main','Blocked',jsonb_build_array(pg_temp.own('first')))$$,'RT009','archived','Archived edit denied');
select set_config('request.jwt.claims','{}',true);
select throws_ok($$select public.get_routines()$$,'RT001','unauthorized','JWT absent on read');
select throws_ok($$select pg_temp.make_r('no-jwt',jsonb_build_array(pg_temp.own('no-jwt-step')))$$,'RT001','unauthorized','JWT absent on create');
select is((select count(*)::int from public.routines),0,'RLS rejects missing identity');
reset role;
set local role anon;
select throws_ok($$select * from public.routines$$,'42501',null,'anon cannot SELECT');
select throws_ok($$select public.get_routines()$$,'42501',null,'anon cannot invoke read');
select throws_ok($$select pg_temp.make_r('anon-r',jsonb_build_array(pg_temp.own('anon-step')))$$,'42501',null,'anon cannot invoke write');
reset role;
set constraints all immediate;
select ok((select bool_and(relrowsecurity) from pg_class where oid in(
 'public.routines'::regclass,'public.routine_definitions'::regclass,'public.routine_steps'::regclass,
 'public.routine_definition_steps'::regclass,'public.routine_step_day_records'::regclass,'private.routine_operations'::regclass)),'All new tables have RLS');
select ok(not has_table_privilege('service_role','public.routines','SELECT'),'No unnecessary privileged grant');
select ok((select bool_and(proconfig @> array['search_path=""']) from pg_proc where proname in(
 'create_routine','edit_routine','archive_routine','record_routine_step','get_routines')),'Fixed function search paths');
select * from finish();
rollback;
