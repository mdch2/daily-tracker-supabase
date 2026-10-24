begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
insert into auth.users(id,email) values
 ('24000000-0000-4000-8000-000000000001','versions-a@example.test'),
 ('24000000-0000-4000-8000-000000000002','versions-b@example.test');
create function pg_temp.today() returns date language sql as $$ select (clock_timestamp() at time zone 'UTC')::date $$;
create function pg_temp.next_week(p_day smallint) returns date language sql as $$ select pg_temp.today()-((extract(isodow from pg_temp.today())::int-p_day+7)%7)+7 $$;
create function pg_temp.edit(p_op text,p_target bigint,p_expected timestamptz,p_schedule text default 'weekly',p_weekly smallint default 3)
returns jsonb language sql as $$ select public.edit_habit(md5(p_op)::uuid,md5('versions-quantity')::uuid,'Updated immediately',p_expected,p_schedule,null,p_weekly,p_target) $$;
grant execute on function pg_temp.today(),pg_temp.next_week(smallint),pg_temp.edit(text,bigint,timestamptz,text,smallint) to authenticated,anon;
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"24000000-0000-4000-8000-000000000001","role":"authenticated"}',true);
select public.initialize_habit_calendar('UTC',1::smallint);
select public.create_habit(md5('versions-quantity')::uuid,'Original','quantity','daily',null,null,20000,'pages');
select public.create_habit(md5('versions-history')::uuid,'Historical','quantity','daily',null,null,20000,'pages');
reset role;
create temp table original_versions as select h.updated_at,d.id as definition_id,d.target_milliunits from public.habits h
 join public.habit_definitions d on d.habit_id=h.id where h.id=md5('versions-quantity')::uuid;
grant select on original_versions to authenticated;
select ok(not has_function_privilege('anon','public.edit_habit(uuid,uuid,text,timestamptz,text,smallint,smallint,bigint)','execute'),'Anon cannot edit definitions');
select ok(not has_function_privilege('service_role','public.edit_habit(uuid,uuid,text,timestamptz,text,smallint,smallint,bigint)','execute'),'No privileged client grant');
set local role authenticated;
select set_config('request.jwt.claims','{"role":"authenticated"}',true);
select throws_ok($$select pg_temp.edit('no-sub',30000,now())$$,'HT001','unauthorized','Missing identity rejected');
select set_config('request.jwt.claims','{"sub":"24000000-0000-4000-8000-000000000002","role":"authenticated"}',true);
select throws_ok($$select pg_temp.edit('cross-owner',30000,now())$$,'HT004','not_found','Cross-owner configuration rejected');
select public.initialize_habit_calendar('America/Bogota',7::smallint);
select public.create_habit(md5('sunday-habit')::uuid,'Sunday','binary','daily');
select is((public.edit_habit(md5('sunday-edit')::uuid,md5('sunday-habit')::uuid,'Sunday updated',
 (select updated_at from public.habits where id=md5('sunday-habit')::uuid),'weekly',null,2::smallint,null)->>'effective_from')::date,
 ((clock_timestamp() at time zone 'America/Bogota')::date
 -((extract(isodow from (clock_timestamp() at time zone 'America/Bogota')::date)::int-7+7)%7)+7),'Sunday uses the account timezone and week boundary');
select throws_ok($$select public.edit_habit(md5('binary-quantity')::uuid,md5('sunday-habit')::uuid,'bad',
 (select updated_at from public.habits where id=md5('sunday-habit')::uuid),'daily',null,null,1)$$,'HT003','invalid_input','Binary cannot acquire a quantitative target');
select set_config('request.jwt.claims','{"sub":"24000000-0000-4000-8000-000000000001","role":"authenticated"}',true);
select throws_ok($$select pg_temp.edit('invalid-target',0,(select updated_at from original_versions))$$,'HT003','invalid_input','Positive quantity goal required');
select throws_ok($$select pg_temp.edit('invalid-weekly',30000,(select updated_at from original_versions),'weekly',8::smallint)$$,'HT003','invalid_input','Weekly count bounded');
select is((pg_temp.edit('edit-first',30000,(select updated_at from original_versions))->>'effective_from')::date,pg_temp.next_week(1::smallint),'Next Monday is the effective date');
select is((select name from public.habits where id=md5('versions-quantity')::uuid),'Updated immediately','Name changes immediately');
select is((select count(*)::int from public.habit_definitions where habit_id=md5('versions-quantity')::uuid),2,'Initial and future definitions retained');
select is((select target_milliunits from public.habit_definitions where id=(select definition_id from original_versions)),20000::bigint,'Initial goal is immutable');
select is((select schedule_type from public.habit_definitions where id=(select definition_id from original_versions)),'daily','Initial frequency remains daily');
select lives_ok($$select public.record_habit_day(md5('still-today')::uuid,md5('versions-quantity')::uuid,pg_temp.today(),'add_amount',null,20000)$$,'Today still records against current definition');
select is((select definition_id from public.habit_day_records where habit_id=md5('versions-quantity')::uuid),(select definition_id from original_versions),'Today does not use the future definition');
select throws_ok($$select public.record_habit_day(md5('future-record')::uuid,md5('versions-quantity')::uuid,pg_temp.next_week(1::smallint),'add_amount',null,30000)$$,'HT006','outside_window','Pending version does not enable future records');
select lives_ok($$select pg_temp.edit('edit-second',40000,(select updated_at from public.habits where id=md5('versions-quantity')::uuid))$$,'Can revise pending configuration before activation');
select is((select count(*)::int from public.habit_definitions where habit_id=md5('versions-quantity')::uuid),2,'Replacing a pending configuration does not add overlapping versions');
select lives_ok($$select pg_temp.edit('edit-first',30000,(select updated_at from original_versions))$$,'Old uncertain edit replays its receipt');
select is((select target_milliunits from public.habit_definitions where habit_id=md5('versions-quantity')::uuid order by effective_from desc limit 1),40000::bigint,'Old receipt cannot overwrite latest planned target');
select throws_ok($$select pg_temp.edit('stale-edit',50000,(select updated_at from original_versions))$$,'HT008','revision_conflict','Stale configuration edit conflicts');
select lives_ok($$select public.create_habit(md5('versions-quantity')::uuid,'Original','quantity','daily',null,null,20000,'pages')$$,'Original create retry survives name and definition changes');
reset role;
-- Synthetic already-effective transition to exercise historical writes without changing the server clock.
update public.habits set start_date=pg_temp.today()-14 where id=md5('versions-history')::uuid;
update public.habit_definitions set effective_from=pg_temp.today()-14 where habit_id=md5('versions-history')::uuid;
insert into public.habit_definitions(habit_id,user_id,effective_from,measurement_mode,schedule_type,weekly_target,target_milliunits,unit_label,time_zone,week_start_day)
 values(md5('versions-history')::uuid,'24000000-0000-4000-8000-000000000001',pg_temp.next_week(1::smallint)-7,'quantity','weekly',3,50000,'pages','UTC',1);
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"24000000-0000-4000-8000-000000000001","role":"authenticated"}',true);
select lives_ok($$select public.record_habit_day(md5('historical-correction')::uuid,md5('versions-history')::uuid,pg_temp.next_week(1::smallint)-8,'add_amount',null,15000)$$,'Previous-week correction remains available');
select is((select d.target_milliunits from public.habit_day_records r join public.habit_definitions d on d.id=r.definition_id
 where r.habit_id=md5('versions-history')::uuid and r.occurrence_date=pg_temp.next_week(1::smallint)-8),20000::bigint,'Correction keeps the historical goal');
select lives_ok($$select public.record_habit_day(md5('current-version')::uuid,md5('versions-history')::uuid,pg_temp.today(),'add_amount',null,50000)$$,'Current-week write uses the effective version');
select is((select d.target_milliunits from public.habit_day_records r join public.habit_definitions d on d.id=r.definition_id
 where r.habit_id=md5('versions-history')::uuid and r.occurrence_date=pg_temp.today()),50000::bigint,'Active goal selected by occurrence date');
select throws_ok($$update public.habit_definitions set target_milliunits=1$$,'42501',null,'Client cannot rewrite any historical definition');
select * from finish();
rollback;
