begin;
create extension if not exists pgtap with schema extensions;
do $$ declare routine record; begin
  for routine in select p.oid::regprocedure as signature from pg_proc p
    join pg_depend d on d.classid = 'pg_proc'::regclass and d.objid = p.oid and d.deptype = 'e'
    join pg_extension e on e.oid = d.refobjid where e.extname = 'pgtap'
  loop execute format('grant execute on function %s to anon, authenticated', routine.signature); end loop;
end $$;
select no_plan();
insert into auth.users (id, email) values
 ('21000000-0000-4000-8000-000000000001','habit-a@example.test'),
 ('21000000-0000-4000-8000-000000000002','habit-b@example.test');
create function pg_temp.today() returns date language sql as $$ select (clock_timestamp() at time zone 'UTC')::date $$;
create function pg_temp.make(p_key text, p_mode text, p_schedule text, p_mask smallint default null, p_weekly smallint default null)
returns uuid language sql as $$ select public.create_habit(md5(p_key)::uuid, p_key, p_mode, p_schedule, p_mask, p_weekly,
  case when p_mode = 'quantity' then 20000::bigint end, case when p_mode = 'quantity' then 'pages' end) $$;
create function pg_temp.record(p_op text, p_habit text, p_kind text, p_amount bigint default null,
  p_binary boolean default null, p_revision bigint default null, p_days integer default 0)
returns jsonb language sql as $$ select public.record_habit_day(md5(p_op)::uuid,md5(p_habit)::uuid,pg_temp.today()+p_days,
  p_kind,p_binary,p_amount,p_revision) $$;
grant execute on function pg_temp.today(), pg_temp.make(text,text,text,smallint,smallint),
  pg_temp.record(text,text,text,bigint,boolean,bigint,integer) to authenticated, anon;

set local role authenticated;
select set_config('request.jwt.claims','{"sub":"21000000-0000-4000-8000-000000000001","role":"authenticated"}',true);
select is((select business_date from public.get_habit_context()),null::date,'No inferred calendar before selection');
select throws_ok($$select pg_temp.make('early','binary','daily')$$,'HT002','calendar_required','Calendar required before creation');
select throws_ok($$select public.initialize_habit_calendar('Invalid/Zone',1::smallint)$$,'HT003','invalid_input','Invalid zone rejected');
select throws_ok($$select public.initialize_habit_calendar('UTC',2::smallint)$$,'HT003','invalid_input','Invalid week start rejected');
select lives_ok($$select public.initialize_habit_calendar('UTC',1::smallint)$$,'Initial calendar confirmed');
select lives_ok($$select public.initialize_habit_calendar('UTC',1::smallint)$$,'Calendar replay is idempotent');
select throws_ok($$select public.initialize_habit_calendar('America/Bogota',7::smallint)$$,'HT009','calendar_locked','Calendar changes deferred');
select throws_ok($$update public.profiles set time_zone='America/Bogota'$$,'42501',null,'Cannot bypass calendar RPC');
select throws_ok($$update public.profiles set week_start_day=7$$,'42501',null,'Cannot bypass week start RPC');
select is((select business_date from public.get_habit_context()),pg_temp.today(),'Server determines business date');
select is((select week_start_date from public.get_habit_context()),
 pg_temp.today()-((extract(isodow from pg_temp.today())::int-1+7)%7),'Monday week boundary');
select lives_ok($$select pg_temp.make('bdaily','binary','daily')$$,'Binary daily');
select lives_ok($$select pg_temp.make('bweekdays','binary','weekdays',127::smallint)$$,'Binary weekdays');
select lives_ok($$select pg_temp.make('bweekly','binary','weekly',null,3::smallint)$$,'Binary flexible week');
select lives_ok($$select pg_temp.make('qdaily','quantity','daily')$$,'Quantity daily');
select lives_ok($$select pg_temp.make('qweekdays','quantity','weekdays',127::smallint)$$,'Quantity weekdays');
select lives_ok($$select pg_temp.make('qweekly','quantity','weekly',null,3::smallint)$$,'Quantity flexible week');
select is((select count(*)::int from public.habits),6,'Six owned habits');
select lives_ok($$select pg_temp.make('bdaily','binary','daily')$$,'Create retry returns existing habit');
select throws_ok($$select public.create_habit(md5('bdaily')::uuid,'changed','binary','daily')$$,
 'HT005','operation_reused','Cannot reuse habit identity with different content');
select throws_ok($$select pg_temp.make('bad','binary','weekly',null,8::smallint)$$,'HT003','invalid_input','Weekly target max seven');
select throws_ok($$select pg_temp.make('bad','binary','weekdays',null)$$,'HT003','invalid_input','Weekdays required');
select throws_ok($$select public.create_habit(md5('bad')::uuid,'bad','quantity','daily',null,null,0,'pages')$$,
 'HT003','invalid_input','Positive target required');
select is((select count(*)::int from public.habits),6,'Rejected creation leaves no orphan habit');
select throws_ok($$insert into public.habits(id,user_id,name,start_date) values (gen_random_uuid(),auth.uid(),'bypass',pg_temp.today())$$,
 '42501',null,'Direct habit INSERT denied');
select throws_ok($$update public.habits set user_id=gen_random_uuid()$$,'42501',null,'Owner cannot transfer ownership');
select throws_ok($$update public.habit_definitions set target_milliunits=1$$,'42501',null,'Definitions immutable to clients');
select throws_ok($$delete from public.habits$$,'42501',null,'No destructive client deletion');
select throws_ok($$select * from private.habit_day_operations$$,'42501',null,'Receipts remain internal');
select throws_ok($$update public.habits set created_at=now()$$,'42501',null,'Server timestamps protected');

select is((pg_temp.record('binary1','bdaily','set_binary',null,true,0)->>'revision')::int,1,'First binary revision');
select is((pg_temp.record('binary1','bdaily','set_binary',null,true,0)->>'revision')::int,1,'Binary replay does not increment');
select throws_ok($$select pg_temp.record('binary1','bdaily','set_binary',null,false,1)$$,
 'HT005','operation_reused','Operation content immutable');
select throws_ok($$select pg_temp.record('binary-stale','bdaily','set_binary',null,false,0)$$,
 'HT008','revision_conflict','Stale binary edit conflicts');
select lives_ok($$select pg_temp.record('binary2','bdaily','set_binary',null,false,1)$$,'Binary reversal confirmed');
select is((select binary_value from public.habit_day_records where habit_id=md5('bdaily')::uuid),false,'Reversal preserves explicit false');
select is((select count(*)::int from public.habit_day_records where habit_id=md5('bdaily')::uuid),1,'One state per date');
select throws_ok($$insert into public.habit_day_records select * from public.habit_day_records$$,'42501',null,'Direct day INSERT denied');
select throws_ok($$update public.habit_day_records set amount_milliunits=1$$,'42501',null,'Direct day UPDATE denied');
select throws_ok($$delete from public.habit_day_records$$,'42501',null,'Direct day DELETE denied');
select is((pg_temp.record('A','qdaily','add_amount',250000)->>'amount_milliunits')::bigint,250000::bigint,'A adds 250');
select is((pg_temp.record('A','qdaily','add_amount',250000)->>'amount_milliunits')::bigint,250000::bigint,'Retry A no duplicate');
select is((pg_temp.record('B','qdaily','add_amount',250000)->>'amount_milliunits')::bigint,500000::bigint,'B adds another 250');
select is((pg_temp.record('C','qdaily','set_total',750000,null,2)->>'amount_milliunits')::bigint,750000::bigint,'Set total replaces');
select is((pg_temp.record('D','qdaily','add_amount',250000)->>'amount_milliunits')::bigint,1000000::bigint,'D adds to corrected total');
select is((pg_temp.record('C','qdaily','set_total',750000,null,2)->>'revision')::int,3,'Old replay returns original receipt');
select is((select amount_milliunits from public.habit_day_records where habit_id=md5('qdaily')::uuid),1000000::bigint,'Old receipt never rolls back current state');
select throws_ok($$select pg_temp.record('stale','qdaily','set_total',1,null,3)$$,'HT008','revision_conflict','Stale total conflicts');
select throws_ok($$select pg_temp.record('zero-add','qdaily','add_amount',0)$$,'HT003','invalid_input','Zero contribution rejected');
select throws_ok($$select pg_temp.record('negative','qdaily','set_total',-1,null,4)$$,'HT003','invalid_input','Negative total rejected');
select throws_ok($$select pg_temp.record('wrong-mode','qdaily','set_binary',null,true,4)$$,'HT003','invalid_input','Wrong modality rejected');
select lives_ok($$select pg_temp.record('clear','qdaily','set_total',0,null,4)$$,'Explicit zero correction accepted');
select is((select amount_milliunits from public.habit_day_records where habit_id=md5('qdaily')::uuid),0::bigint,'Zero distinct from no record');
select lives_ok($$select pg_temp.record('limit','qdaily','set_total',999999999999,null,5)$$,'Maximum amount accepted');
select throws_ok($$select pg_temp.record('overflow','qdaily','add_amount',1)$$,'HT010','amount_limit','Overflow rejected atomically');
select is((select revision from public.habit_day_records where habit_id=md5('qdaily')::uuid),6::bigint,'Rejected writes do not increment revision');
select throws_ok($$select pg_temp.record('future','qdaily','add_amount',1,null,null,1)$$,'HT006','outside_window','Future rejected');
select throws_ok($$select pg_temp.record('before-start','qdaily','add_amount',1,null,null,-1)$$,'HT007','ineligible_date','Before creation rejected');
select lives_ok($$select pg_temp.make('not-today','binary','weekdays',
 (127 # (1 << (extract(isodow from pg_temp.today())::int-1)))::smallint)$$,'Create noneligible weekday habit');
select throws_ok($$select pg_temp.record('offday','not-today','set_binary',null,true,0)$$,'HT007','ineligible_date','Unscheduled date rejected');

-- Historical fixtures only, never a client capability.
reset role;
update public.habits set start_date=pg_temp.today()-20 where id in (md5('qdaily')::uuid,md5('qweekly')::uuid);
update public.habit_definitions set effective_from=pg_temp.today()-20 where habit_id in (md5('qdaily')::uuid,md5('qweekly')::uuid);
set local role authenticated;
select lives_ok($$select pg_temp.record('historical7','qdaily','add_amount',15000,null,null,-7)$$,'D-7 accepted');
select throws_ok($$select pg_temp.record('historical8','qdaily','add_amount',15000,null,null,-8)$$,'HT006','outside_window','D-8 rejected');
select lives_ok($$select pg_temp.record('historical-correct','qdaily','set_total',20000,null,1,-7)$$,'Historical total can reach target');
select lives_ok($$select pg_temp.record('historical-reduce','qdaily','set_total',15000,null,2,-7)$$,'Historical total can cease meeting target');
select is((select count(*)::int from public.habit_day_records where habit_id=md5('qdaily')::uuid),2,'History retained beside today');
select lives_ok($$select pg_temp.record('weekly1','qweekly','add_amount',20000,null,null,-1)$$,'Flexible weekly day accepts minimum');
select lives_ok($$select pg_temp.record('weekly2','qweekly','add_amount',20000,null,null,-1)$$,'Additional contribution same date');
select is((select count(*)::int from public.habit_day_records where habit_id=md5('qweekly')::uuid),1,'Contributions do not become multiple days');

select set_config('request.jwt.claims','{"sub":"21000000-0000-4000-8000-000000000002","role":"authenticated"}',true);
select is((select count(*)::int from public.habits),0,'B cannot read A habits');
select is((select count(*)::int from public.habit_definitions),0,'B cannot read A definitions');
select is((select count(*)::int from public.habit_day_records),0,'B cannot read A records');
select throws_ok($$select pg_temp.record('intrusion','qdaily','add_amount',1000)$$,'HT004','not_found','Cross-owner command rejected');
select throws_ok($$select pg_temp.make('bdaily','binary','daily')$$,'HT002','calendar_required','B cannot create without own calendar');
select lives_ok($$select public.initialize_habit_calendar('UTC',7::smallint)$$,'B selects Sunday independently');
select lives_ok($$select pg_temp.make('other-habit','binary','daily')$$,'B creates owned habit');
select is((select week_start_date from public.get_habit_context()),
 pg_temp.today()-(extract(isodow from pg_temp.today())::int%7),'Sunday week boundary');
select throws_ok($$select pg_temp.make('bdaily','binary','daily')$$,'HT004','not_found','Cannot take another habit UUID');
select set_config('request.jwt.claims','{"sub":"21000000-0000-4000-8000-000000000001","role":"authenticated"}',true);
select is((select count(*)::int from public.habits where id=md5('other-habit')::uuid),0,'A cannot read B habit');
select throws_ok($$select pg_temp.record('reverse-intrusion','other-habit','set_binary',null,true,0)$$,
 'HT004','not_found','Reverse cross-owner command rejected');
select set_config('request.jwt.claims','{}',true);
select is((select count(*)::int from public.habits),0,'Missing JWT sees no habits');
select throws_ok($$select pg_temp.record('no-jwt','bdaily','set_binary',null,true,0)$$,'HT001','unauthorized','RPC requires subject');
select throws_ok($$select public.get_habit_context()$$,'HT001','unauthorized','Context requires subject');
reset role;
set local role anon;
select throws_ok($$select * from public.habits$$,'42501',null,'Anon cannot read habits');
select throws_ok($$select * from public.habit_definitions$$,'42501',null,'Anon cannot read definitions');
select throws_ok($$select * from public.habit_day_records$$,'42501',null,'Anon cannot read days');
select throws_ok($$select public.get_habit_context()$$,'42501',null,'Anon cannot execute context');
select throws_ok($$select public.initialize_habit_calendar('UTC',1::smallint)$$,'42501',null,'Anon cannot configure calendar');
select throws_ok($$select pg_temp.record('anon','bdaily','set_binary',null,true,0)$$,'42501',null,'Anon cannot execute writes');
reset role;
select ok(private.habit_date_writable('2026-10-14','2026-10-21'),'Exact D-7 inclusive');
select ok(not private.habit_date_writable('2026-10-13','2026-10-21'),'Exact D-8 excluded');
select ok(not private.habit_date_writable('2026-10-14','2026-10-22'),'Midnight expires new acceptance');
select is(('2026-03-08 05:00+00'::timestamptz at time zone 'America/New_York')::date,'2026-03-08'::date,'DST date uses selected zone');
select is(extract(epoch from ('2026-03-09'::timestamp at time zone 'America/New_York')-
 ('2026-03-08'::timestamp at time zone 'America/New_York'))::int,82800,'DST day is 23 hours, not fixed duration');
select ok(not has_function_privilege('authenticated','private.habit_date_writable(date,date)','EXECUTE'),'No test clock exposed to clients');
select ok(not has_function_privilege('service_role','public.record_habit_day(uuid,uuid,date,text,boolean,bigint,bigint)','EXECUTE'),'No unneeded server RPC grant');
select ok(not exists (select 1 from pg_proc where pronamespace='public'::regnamespace and proname in
 ('create_habit','record_habit_day','initialize_habit_calendar') and not proconfig @> array['search_path=""']),'Definer search paths pinned');
select throws_ok($$insert into public.habit_definitions(habit_id,user_id,effective_from,measurement_mode,schedule_type,time_zone,week_start_day)
 values (md5('not-existing')::uuid,'21000000-0000-4000-8000-000000000002',pg_temp.today(),'quantity','daily','UTC',1)$$,
 '23514',null,'Conditional CHECK rejects NULL target and unit');
select is((select count(*)::int from private.habit_day_operations where operation_id=md5('overflow')::uuid),0,'Rejected command leaves no receipt');
-- An already accepted command is replayable even after its date leaves the window.
update private.habit_day_operations set request=jsonb_set(request,'{occurrence_date}',to_jsonb((pg_temp.today()-8)::text))
 where operation_id=md5('historical7')::uuid;
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"21000000-0000-4000-8000-000000000001","role":"authenticated"}',true);
select lives_ok($$select pg_temp.record('historical7','qdaily','add_amount',15000,null,null,-8)$$,'Confirmed operation replays outside window without new write');
reset role;
select * from finish();
rollback;
