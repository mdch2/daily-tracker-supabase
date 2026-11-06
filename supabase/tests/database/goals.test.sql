begin;
set local client_min_messages=error;
create extension if not exists pgtap with schema extensions;
do $$ declare f record; begin
 for f in select p.oid::regprocedure as signature from pg_proc p join pg_depend d on d.classid='pg_proc'::regclass and d.objid=p.oid and d.deptype='e'
 join pg_extension e on e.oid=d.refobjid where e.extname='pgtap' loop
 execute format('grant execute on function %s to anon,authenticated',f.signature); end loop;
end $$;
select no_plan();
insert into auth.users(id,email) values
 ('30000000-0000-4000-8000-000000000001','goal-a@example.test'),('30000000-0000-4000-8000-000000000002','goal-b@example.test');
create function pg_temp.gday(p_offset int default 0) returns text language sql as $$
 select ((clock_timestamp() at time zone 'UTC')::date+p_offset)::text $$;
create function pg_temp.gbase(k text) returns jsonb language sql as $$
 select jsonb_build_object('operation_id',md5(k||'-create')::uuid,'goal_id',md5(k)::uuid,'name',k,'description',null,'start_date',pg_temp.gday(),'deadline',null) $$;
create function pg_temp.gamount(k text) returns jsonb language sql as $$
 select pg_temp.gbase(k)||jsonb_build_object('mode','amount','progress_source','manual','unit_label','units','target_milliunits',10000) $$;
create function pg_temp.glink(k text,metric text,mode_value text default 'amount') returns jsonb language sql as $$
 select pg_temp.gbase(k)||jsonb_build_object('mode',mode_value,'progress_source','habit','habit_id',md5('goal-habit')::uuid,'linked_metric',metric) ||
 case when mode_value='amount' then jsonb_build_object('target_milliunits',case when metric='amount' then 30000 else 1000 end)
 else jsonb_build_object('milestones',jsonb_build_array(jsonb_build_object('id',md5(k||'1')::uuid,'name','First','threshold_milliunits',10000),
 jsonb_build_object('id',md5(k||'2')::uuid,'name','Second','threshold_milliunits',30000))) end $$;
create function pg_temp.grecord(op text,k text,n bigint,rev bigint default null,day_offset int default 0) returns jsonb language sql as $$
 select public.record_goal_amount(jsonb_build_object('operation_id',md5(op)::uuid,'goal_id',md5(k)::uuid,'date',pg_temp.gday(day_offset),
 'action',case when rev is null then 'add' else 'set' end,'amount_milliunits',n) ||
 case when rev is null then '{}'::jsonb else jsonb_build_object('expected_revision',rev) end) $$;
create function pg_temp.gread(k text) returns jsonb language sql as $$
 select public.get_goal(jsonb_build_object('goal_id',md5(k)::uuid))->'goal' $$;
create function pg_temp.ghistory(k text) returns jsonb language sql as $$
 select public.get_goal_history(jsonb_build_object('goal_id',md5(k)::uuid,'before_sequence',null,'up_to_sequence',null)) $$;
create function pg_temp.gedit(op text,k text,target bigint,version_value bigint,deadline_value text default null) returns jsonb language sql as $$
 select public.edit_goal(jsonb_build_object('operation_id',md5(op)::uuid,'goal_id',md5(k)::uuid,'expected_version',version_value,
 'name',k,'description',null,'target_milliunits',target,'deadline',deadline_value)) $$;
create function pg_temp.gmilestone(op text,done boolean,rev bigint,day_offset int default null) returns jsonb language sql as $$
 select public.record_goal_milestone(jsonb_build_object('operation_id',md5(op)::uuid,'goal_id',md5('old-milestones')::uuid,
 'milestone_id',md5('old-milestone')::uuid,'completed',done,'expected_revision',rev,
 'completion_date',case when day_offset is not null then pg_temp.gday(day_offset) end)) $$;
grant execute on all functions in schema pg_temp to authenticated,anon;
create temp table goal_pages(n int primary key,doc jsonb);
grant select,insert on goal_pages to authenticated;
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"30000000-0000-4000-8000-000000000001","role":"authenticated"}',true);
select throws_ok($$select public.create_goal(pg_temp.gamount('no-calendar'))$$,'GL002','calendar_required','Calendar is mandatory');
select public.initialize_habit_calendar('UTC',1::smallint);
select lives_ok($$select public.create_goal(pg_temp.gamount('manual')||jsonb_build_object('description',repeat('😀',400)))$$,'400 Unicode code points accepted');
select throws_ok($$select public.create_goal(pg_temp.gamount('too-long')||jsonb_build_object('description',repeat('a',401)))$$,'GL003','invalid_input','401 rejected');
select throws_ok($$select public.create_goal(pg_temp.gamount('unknown')||'{"user_id":"30000000-0000-4000-8000-000000000002"}')$$,'GL003','invalid_input','Client ownership rejected');
select throws_ok($$select public.create_goal(pg_temp.gamount('bad-number')||'{"target_milliunits":"10000"}')$$,'GL003','invalid_input','Numeric strings rejected');
select throws_ok($$select public.create_goal(pg_temp.gamount('bad-date')||'{"start_date":"2026-02-30"}')$$,'GL003','invalid_input','Invalid calendar dates rejected');
select throws_ok($$select public.create_goal(pg_temp.gamount('past')||jsonb_build_object('start_date',pg_temp.gday(-1)))$$,'GL007','ineligible_date','No retroactive creation');
select lives_ok($$select public.create_goal(pg_temp.gamount('future')||jsonb_build_object('start_date',pg_temp.gday(5)))$$,'Future start accepted');
select is(pg_temp.gread('future')->>'state','scheduled','Future goal scheduled');
select throws_ok($$select pg_temp.grecord('future-op','future',1)$$,'GL007','ineligible_date','No progress before start');
select is((pg_temp.grecord('add1','manual',4000)->>'revision')::int,1,'Manual addition confirmed');
select is((pg_temp.grecord('add1','manual',4000)->>'revision')::int,1,'Replay returns original revision');
select throws_ok($$select pg_temp.grecord('add1','manual',4001)$$,'GL005','operation_reused','Reused UUID rejects different content');
select throws_ok($$select pg_temp.grecord('stale','manual',1,0)$$,'GL008','revision_conflict','Stale substitution rejected');
select is((pg_temp.grecord('zero','manual',0,1)->>'revision')::int,2,'Zero is a confirmed total');
select is((public.get_goal_contributions(jsonb_build_object('goal_id',md5('manual')::uuid,'from',pg_temp.gday(),'to',pg_temp.gday()))->'days'->0->>'recorded')::boolean,true,'Zero differs from absence');
select is((pg_temp.grecord('over','manual',15000)->>'amount_milliunits')::bigint,15000::bigint,'Over-target amount preserved');
select is(pg_temp.gread('manual')->>'state','achieved','Goal achieved');
select is((pg_temp.gread('manual')->'progress'->>'percentage')::int,100,'Display capped at 100');
select lives_ok($$select pg_temp.gedit('raise-target','manual',20000,1)$$,'Target edits immediate');
select is(pg_temp.gread('manual')->>'state','in_progress','Raising target reopens goal');
select throws_ok($$select pg_temp.gedit('old-config','manual',1,1)$$,'GL008','revision_conflict','Configuration versions enforced');
select throws_ok($$select public.edit_goal(jsonb_build_object('operation_id',md5('bad-structure')::uuid,'goal_id',md5('manual')::uuid,
 'expected_version',2,'name','manual','description',null,'deadline',null,'target_milliunits',20000,'mode','milestones'))$$,'GL003','invalid_input','Structure is immutable');
select throws_ok($$select pg_temp.grecord('bad-zero','manual',0)$$,'GL003','invalid_input','Addition must be positive');
select throws_ok($$select pg_temp.grecord('limit','manual',999999999999)$$,'GL010','amount_limit','Accumulated range enforced');
select is((pg_temp.gread('manual')->'progress'->>'accumulated_milliunits')::bigint,15000::bigint,'Failure leaves total unchanged');

-- Historical synthetic data represents previously created goals, not a retroactive client API.
reset role;
insert into public.goals(id,user_id,mode,progress_source,start_date,time_zone,unit_label)
 values(md5('old-amount')::uuid,'30000000-0000-4000-8000-000000000001','amount','manual',pg_temp.gday(-40)::date,'UTC','units');
insert into public.goal_versions(goal_id,user_id,version,name,target_milliunits)
 values(md5('old-amount')::uuid,'30000000-0000-4000-8000-000000000001',1,'Old amount',10000);
insert into public.goals(id,user_id,mode,progress_source,start_date,time_zone)
 values(md5('old-milestones')::uuid,'30000000-0000-4000-8000-000000000001','milestones','manual',pg_temp.gday(-40)::date,'UTC');
insert into public.goal_versions(goal_id,user_id,version,name)
 values(md5('old-milestones')::uuid,'30000000-0000-4000-8000-000000000001',1,'Old milestones');
insert into public.goal_milestones(id,goal_id,user_id,position,name)
 values(md5('old-milestone')::uuid,md5('old-milestones')::uuid,'30000000-0000-4000-8000-000000000001',0,'Old milestone');
set local role authenticated;
select lives_ok($$select pg_temp.grecord('seven','old-amount',1000,null,-7)$$,'D-7 manual amount accepted');
select throws_ok($$select pg_temp.grecord('eight','old-amount',1000,null,-8)$$,'GL006','outside_window','D-8 manual amount rejected');
select lives_ok($$select pg_temp.gmilestone('old-confirm',true,0,-30)$$,'Ancient milestone can be confirmed');
select lives_ok($$select pg_temp.gmilestone('old-date',true,1,-25)$$,'Ancient milestone date can be corrected');
select lives_ok($$select pg_temp.gmilestone('old-revert',false,2)$$,'Ancient milestone can be reversed');
select is(pg_temp.gread('old-milestones')->'milestone_states'->0->>'completion_date',null,'Reversion clears current date');
select is(pg_temp.ghistory('old-milestones')->'events'->0->'before'->>'completion_date',pg_temp.gday(-25),'Reversion preserves previous date in history');
select throws_ok($$select pg_temp.gmilestone('too-early',true,3,-41)$$,'GL007','ineligible_date','Milestone cannot predate goal');
select throws_ok($$select pg_temp.gmilestone('tomorrow',true,3,1)$$,'GL007','ineligible_date','Milestone cannot be in future');
select throws_ok($$select public.get_goal_contributions(jsonb_build_object('goal_id',md5('manual')::uuid,'from',pg_temp.gday(-31),'to',pg_temp.gday()))$$,'GL003','invalid_input','Date reads bounded');
select is((public.get_goal_contributions(jsonb_build_object('goal_id',md5('manual')::uuid,'from',pg_temp.gday(-1),'to',pg_temp.gday()))->'days'->0->>'in_window')::boolean,false,'Dates before start excluded');

select public.create_habit(md5('goal-habit')::uuid,'Synthetic reading','quantity','daily',null,null,20000,'pages');
select public.record_habit_day(md5('habit-first')::uuid,md5('goal-habit')::uuid,pg_temp.gday()::date,'add_amount',null,10000);
select lives_ok($$select public.create_goal(pg_temp.glink('linked-amount','amount'))$$,'Linked amount created after source record');
select lives_ok($$select public.create_goal(pg_temp.glink('linked-days','completed_days'))$$,'Linked days created');
select is((pg_temp.gread('linked-amount')->'progress'->>'accumulated_milliunits')::bigint,10000::bigint,'Includes earlier same-day partial amount');
select is((pg_temp.gread('linked-days')->'progress'->>'accumulated_milliunits')::bigint,0::bigint,'Partial amount is not a completed day');
select is((pg_temp.gread('linked-amount')->'progress'->>'percentage')::int,33,'Percentage floors fractional result');
select public.record_habit_day(md5('habit-second')::uuid,md5('goal-habit')::uuid,pg_temp.gday()::date,'add_amount',null,20000);
select is((pg_temp.gread('linked-amount')->'progress'->>'accumulated_milliunits')::bigint,30000::bigint,'Daily source total counted once');
select is((pg_temp.gread('linked-days')->'progress'->>'accumulated_milliunits')::bigint,1000::bigint,'At most one completed day');
select lives_ok($$select public.create_goal(pg_temp.glink('linked-milestones','amount','milestones'))$$,'Threshold milestones created');
select is((pg_temp.gread('linked-milestones')->'progress'->>'completed_milestones')::int,2,'Thresholds complete automatically');
select throws_ok($$select pg_temp.grecord('linked-manual','linked-amount',1)$$,'GL003','invalid_input','No manual amount on linked goal');
select throws_ok($$select public.create_goal(pg_temp.glink('bad-days','completed_days')||'{"target_milliunits":1500}')$$,'GL003','invalid_input','Days must be integral');
select throws_ok($$select public.create_goal(pg_temp.glink('bad-unit','amount')||'{"unit_label":"books"}')$$,'GL003','invalid_input','No unit conversion or override');
select public.record_habit_day(md5('habit-correct')::uuid,md5('goal-habit')::uuid,pg_temp.gday()::date,'set_total',null,5000,2);
select is(pg_temp.gread('linked-milestones')->>'state','in_progress','Correction reopens linked milestones');
select is((pg_temp.gread('linked-milestones')->'progress'->>'completed_milestones')::int,0,'Correction can uncomplete every threshold');
select public.archive_goal(jsonb_build_object('operation_id',md5('archive-link')::uuid,'goal_id',md5('linked-amount')::uuid,'expected_version',1));
select public.record_habit_day(md5('after-archive')::uuid,md5('goal-habit')::uuid,pg_temp.gday()::date,'add_amount',null,1000);
select is((pg_temp.gread('linked-amount')->'progress'->>'accumulated_milliunits')::bigint,6000::bigint,'Archive includes later records on archive date');
select is(pg_temp.gread('linked-amount')->>'state','archived','Archive state has priority');
select lives_ok($$select public.archive_goal(jsonb_build_object('operation_id',md5('archive-link')::uuid,'goal_id',md5('linked-amount')::uuid,'expected_version',1))$$,'Archive replay recognized');
select throws_ok($$select pg_temp.gedit('archive-edit','linked-amount',1,2)$$,'GL009','archived','Archived configuration read-only');
select public.archive_goal(jsonb_build_object('operation_id',md5('archive-manual')::uuid,'goal_id',md5('manual')::uuid,'expected_version',2));
select throws_ok($$select pg_temp.grecord('archive-write','manual',1)$$,'GL009','archived','Archived manual writes rejected');
select is((pg_temp.grecord('add1','manual',4000)->>'revision')::int,1,'Original receipt available after archive');
select is((pg_temp.gread('manual')->'progress'->>'accumulated_milliunits')::bigint,15000::bigint,'Replay does not replace current total');

-- Pagination is stable by immutable creation key; counts are for the entire account.
do $$ begin for n in 1..22 loop perform public.create_goal(pg_temp.gamount('page-'||n)); end loop; end $$;
insert into goal_pages values(1,public.get_goals('{"status":null,"cursor":null}'));
select is(jsonb_array_length((select doc->'goals' from goal_pages where n=1)),20,'List page bounded to 20');
select ok((select doc->>'next_cursor' is not null from goal_pages where n=1),'Next cursor provided');
insert into goal_pages values(2,public.get_goals(jsonb_build_object('status',null,'cursor',(select doc->>'next_cursor' from goal_pages where n=1))));
select is((select count(distinct x->'definition'->>'id') from goal_pages p cross join lateral jsonb_array_elements(p.doc->'goals') x),
 (select sum(jsonb_array_length(doc->'goals')) from goal_pages),'Pages do not repeat identities');
select is((public.get_goals('{"status":"archived","cursor":null}')->'counts'->>'archived')::int,2,'State counts independent of filter');
select throws_ok($$select public.get_goals(jsonb_build_object('status','archived','cursor',(select doc->>'next_cursor' from goal_pages where n=1)))$$,'GL003','invalid_input','Cursor bound to status filter');
select throws_ok($$select public.get_goals('{"status":null,"cursor":"garbage"}')$$,'GL003','invalid_input','Malformed cursor rejected');
select is(pg_temp.ghistory('manual')->'events'->0->>'kind','archive','History shows lifecycle event');
select throws_ok($$select public.get_goal_history(jsonb_build_object('goal_id',md5('manual')::uuid,'before_sequence',null,'up_to_sequence',999999))$$,'GL003','invalid_input','Cannot request uncommitted history watermark');

-- Every public definer reader and writer must preserve account isolation.
select set_config('request.jwt.claims','{"sub":"30000000-0000-4000-8000-000000000002","role":"authenticated"}',true);
select public.initialize_habit_calendar('UTC',1::smallint);
select is(pg_temp.gread('manual'),'null'::jsonb,'Foreign detail indistinguishable from missing');
select is(jsonb_array_length(public.get_goals('{"status":null,"cursor":null}')->'goals'),0,'Foreign rows never listed');
select is((select count(*) from public.goals),0::bigint,'RLS filters direct SELECT');
select throws_ok($$select pg_temp.grecord('foreign-write','old-amount',1)$$,'GL004','not_found','Foreign write rejected');
select throws_ok($$select pg_temp.ghistory('manual')$$,'GL004','not_found','Foreign history rejected');
select throws_ok($$select public.get_goal_contributions(jsonb_build_object('goal_id',md5('linked-amount')::uuid,'from',pg_temp.gday(),'to',pg_temp.gday()))$$,'GL004','not_found','Foreign source read rejected');
select throws_ok($$select public.create_goal(pg_temp.glink('foreign-habit','amount'))$$,'GL004','not_found','Foreign habit cannot be linked');
select set_config('request.jwt.claims','{}',true);
select throws_ok($$select public.get_goals('{"status":null,"cursor":null}')$$,'GL001','unauthorized','Absent JWT rejected by reader');
select throws_ok($$select public.create_goal(pg_temp.gamount('no-jwt'))$$,'GL001','unauthorized','Absent JWT rejected by writer');
reset role;
select ok(not has_table_privilege('anon','public.goals','SELECT'),'Anon has no SELECT');
select ok(not has_table_privilege('authenticated','public.goals','INSERT'),'Client cannot directly INSERT');
select ok(not has_table_privilege('authenticated','public.goal_versions','UPDATE'),'Client cannot rewrite history');
select ok(not has_table_privilege('authenticated','public.goal_amount_day_records','UPDATE'),'Client cannot bypass RPC');
select ok(not has_table_privilege('authenticated','private.goal_operations','SELECT'),'Private operations inaccessible');
select ok(not has_function_privilege('authenticated','private.write_goal(text,jsonb)','EXECUTE'),'Private writer inaccessible');
select ok(not has_function_privilege('authenticated','private.read_goals(text,jsonb)','EXECUTE'),'Private reader inaccessible');
select ok(not has_function_privilege('authenticated','private.goal_habit_days(uuid,uuid,date,date)','EXECUTE'),'Private evaluator inaccessible');
select ok(not has_function_privilege('anon','public.get_goal(jsonb)','EXECUTE'),'Anon RPC denied');
select ok(not has_function_privilege('service_role','public.create_goal(jsonb)','EXECUTE'),'No new service-role grant');
select ok((select bool_and(relrowsecurity) from pg_class where oid in ('public.goals'::regclass,'public.goal_versions'::regclass,
 'public.goal_milestones'::regclass,'public.goal_amount_day_records'::regclass,'public.goal_milestone_records'::regclass,'private.goal_operations'::regclass)),'RLS active on all goal tables');
select throws_ok($$update public.goal_versions set name='Rewritten' where goal_id=md5('manual')::uuid$$,'GL003','immutable_goal_history','History immutable even in maintenance');

-- Known domain limits preserve exact state instead of inventing zero.
reset role;
insert into public.habits(id,user_id,name,start_date) values(md5('overflow-habit')::uuid,'30000000-0000-4000-8000-000000000001','Large source',pg_temp.gday(-2)::date);
insert into public.habit_definitions(id,habit_id,user_id,effective_from,measurement_mode,schedule_type,target_milliunits,unit_label,time_zone,week_start_day)
 values(md5('overflow-def')::uuid,md5('overflow-habit')::uuid,'30000000-0000-4000-8000-000000000001',pg_temp.gday(-2)::date,'quantity','daily',1000,'units','UTC',1);
insert into public.habit_day_records(habit_id,user_id,definition_id,occurrence_date,amount_milliunits,revision) values
 (md5('overflow-habit')::uuid,'30000000-0000-4000-8000-000000000001',md5('overflow-def')::uuid,pg_temp.gday(-1)::date,999999999999,1),
 (md5('overflow-habit')::uuid,'30000000-0000-4000-8000-000000000001',md5('overflow-def')::uuid,pg_temp.gday()::date,999999999999,1);
insert into public.goals(id,user_id,mode,progress_source,start_date,time_zone,unit_label,habit_id,linked_metric)
 values(md5('overflow-goal')::uuid,'30000000-0000-4000-8000-000000000001','amount','habit',pg_temp.gday(-2)::date,'UTC','units',md5('overflow-habit')::uuid,'amount');
insert into public.goal_versions(goal_id,user_id,version,name,target_milliunits)
 values(md5('overflow-goal')::uuid,'30000000-0000-4000-8000-000000000001',1,'Large goal',1000);
select set_config('request.jwt.claims','{"sub":"30000000-0000-4000-8000-000000000001","role":"authenticated"}',true);
set local role authenticated;
select is(pg_temp.gread('overflow-goal')->'progress'->>'error','amountLimit','Linked overflow is explicit');
select is(pg_temp.gread('overflow-goal')->>'state','achieved','Overflow state still exact');
select is(pg_temp.gread('overflow-goal')->'progress'->>'accumulated_milliunits',null,'Overflow never truncates to a number');
select public.create_habit(md5('goal-flex')::uuid,'Flexible source','binary','weekly',null,3::smallint);
select public.record_habit_day(md5('flex-done')::uuid,md5('goal-flex')::uuid,pg_temp.gday()::date,'set_binary',true,null,0);
select public.create_goal(pg_temp.glink('flex-days','completed_days')||jsonb_build_object('habit_id',md5('goal-flex')::uuid));
select is((pg_temp.gread('flex-days')->'progress'->>'accumulated_milliunits')::int,1000,'Flexible habit supplies completed dates without daily obligations');
select throws_ok($$select public.create_goal(pg_temp.glink('binary-amount','amount')||jsonb_build_object('habit_id',md5('goal-flex')::uuid))$$,'GL003','invalid_input','Binary source cannot supply accumulated quantity');
do $$ begin for n in 1..25 loop perform pg_temp.grecord('history-'||n,'page-1',1); end loop; end $$;
insert into goal_pages values(3,pg_temp.ghistory('page-1'));
select is(jsonb_array_length((select doc->'events' from goal_pages where n=3)),20,'Audit pagination bounded');
select pg_temp.grecord('newer-history','page-1',1);
insert into goal_pages values(4,public.get_goal_history(jsonb_build_object('goal_id',md5('page-1')::uuid,
 'before_sequence',(select (doc->>'next_before_sequence')::bigint from goal_pages where n=3),
 'up_to_sequence',(select (doc->>'up_to_sequence')::bigint from goal_pages where n=3))));
select is(jsonb_array_length((select doc->'events' from goal_pages where n=4)),6,'History watermark excludes later events');
select is((select max((e->>'sequence')::bigint) from goal_pages p cross join lateral jsonb_array_elements(p.doc->'events') e where p.n=4),6::bigint,'History page respects sequence cursor');
reset role;
insert into auth.users(id,email) values('30000000-0000-4000-8000-000000000003','goal-dst@example.test');
select set_config('request.jwt.claims','{"sub":"30000000-0000-4000-8000-000000000003","role":"authenticated"}',true);
set local role authenticated;
select public.initialize_habit_calendar('America/New_York',1::smallint);
reset role;
select is(private.goal_context('30000000-0000-4000-8000-000000000003','2026-03-08T05:00:00Z')->>'today','2026-03-08','Explicit account timezone across DST');
select is((private.goal_context('30000000-0000-4000-8000-000000000003','2026-03-08T05:00:00Z')->>'next_day_at')::timestamptz,
 '2026-03-09T04:00:00Z'::timestamptz,'Next day follows calendar, not 24 hours');

set constraints all immediate;
select * from finish();
rollback;
