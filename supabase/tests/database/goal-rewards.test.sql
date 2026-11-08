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
 ('31000000-0000-4000-8000-000000000001','reward-a@example.test'),
 ('31000000-0000-4000-8000-000000000002','reward-b@example.test');
create function pg_temp.reward_create(k text,reward_value text) returns jsonb language sql as $$
 select jsonb_build_object('operation_id',md5(k||'-create')::uuid,'goal_id',md5(k)::uuid,
 'name',k,'description',null,'reward',reward_value,'start_date',(clock_timestamp() at time zone 'UTC')::date,
 'deadline',null,'mode','amount','progress_source','manual','unit_label','units','target_milliunits',10000) $$;
create function pg_temp.reward_edit(k text,op text,version_value int,reward_value text) returns jsonb language sql as $$
 select jsonb_build_object('operation_id',md5(op)::uuid,'goal_id',md5(k)::uuid,'expected_version',version_value,
 'name',k,'description',null,'reward',reward_value,'deadline',null,'target_milliunits',10000) $$;
create function pg_temp.reward_read(k text) returns jsonb language sql as $$
 select public.get_goal_v2(jsonb_build_object('goal_id',md5(k)::uuid))->'goal' $$;
grant execute on all functions in schema pg_temp to authenticated,anon;
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"31000000-0000-4000-8000-000000000001","role":"authenticated"}',true);
select public.initialize_habit_calendar('UTC',1::smallint);
select lives_ok($$select public.create_goal_v2(pg_temp.reward_create('reward','  Synthetic reward  '))$$,'Owner creates reward');
select is(pg_temp.reward_read('reward')->'definition'->>'reward','Synthetic reward','Reward trimmed and read');
select lives_ok($$select public.create_goal_v2(pg_temp.reward_create('reward','  Synthetic reward  '))$$,'Retry returns existing receipt');
select is((pg_temp.reward_read('reward')->'definition'->>'version')::int,1,'Retry creates no version');
select throws_ok($$select public.create_goal_v2(pg_temp.reward_create('reward','Other reward'))$$,'GL005','operation_reused','Same operation cannot change reward');
select is(public.get_goal(jsonb_build_object('goal_id',md5('reward')::uuid))->'goal'->'definition' ? 'reward',false,'v1 detail shape preserved');
select is(public.get_goals('{"status":null,"cursor":null}')->'goals'->0->'definition' ? 'reward',false,'v1 list shape preserved');
select is(public.get_goals_v2('{"status":null,"cursor":null}')->'goals'->0->'definition'->>'reward','Synthetic reward','v2 list includes reward');
select lives_ok($$select public.edit_goal_v2(pg_temp.reward_edit('reward','edit-one',1,'New reward'))$$,'Owner edits reward');
select is(pg_temp.reward_read('reward')->'definition'->>'reward','New reward','Edit read back');
select throws_ok($$select public.edit_goal_v2(pg_temp.reward_edit('reward','edit-conflict',1,'Stale reward'))$$,'GL008','revision_conflict','Stale edit rejected');
select is(pg_temp.reward_read('reward')->'definition'->>'reward','New reward','Conflict does not change reward');
select lives_ok($$select public.edit_goal(pg_temp.reward_edit('reward','legacy-edit',2,null)-'reward')$$,'Legacy edit remains supported');
select is(pg_temp.reward_read('reward')->'definition'->>'reward','New reward','Legacy edit preserves reward');
select lives_ok($$select public.edit_goal(pg_temp.reward_edit('reward','legacy-edit',2,null)-'reward')$$,'Legacy retry fingerprint preserved');
select lives_ok($$select public.edit_goal_v2(pg_temp.reward_edit('reward','clear-reward',3,'   '))$$,'Owner clears reward');
select is(pg_temp.reward_read('reward')->'definition'->>'reward',null,'Whitespace becomes null');
select lives_ok($$select public.edit_goal_v2(pg_temp.reward_edit('reward','limit-reward',4,repeat(chr(127873),400)))$$,'400 Unicode code points accepted');
select throws_ok($$select public.edit_goal_v2(pg_temp.reward_edit('reward','long-reward',5,repeat('a',401)))$$,'GL003','invalid_input','Overlong reward rejected');
select is((pg_temp.reward_read('reward')->'definition'->>'version')::int,5,'Rejected reward leaves no partial version');
select is(public.get_goal_history(jsonb_build_object('goal_id',md5('reward')::uuid,'before_sequence',null,'up_to_sequence',null))->'events'->0->'before'->>'reward',null,'History preserves removed value');
select is(char_length(public.get_goal_history(jsonb_build_object('goal_id',md5('reward')::uuid,'before_sequence',null,'up_to_sequence',null))->'events'->0->'after'->>'reward'),400,'History records replacement reward');
select lives_ok($$select public.archive_goal(jsonb_build_object('operation_id',md5('archive-reward')::uuid,'goal_id',md5('reward')::uuid,'expected_version',5))$$,'Archive accepts latest version');
select is(char_length(pg_temp.reward_read('reward')->'definition'->>'reward'),400,'Archive retains reward');
select throws_ok($$select public.edit_goal_v2(pg_temp.reward_edit('reward','archived-edit',6,'Forbidden'))$$,'GL009','archived','Archived reward cannot be edited');
select lives_ok($$select public.create_goal(pg_temp.reward_create('legacy',null)-'reward')$$,'Legacy create remains supported');
select is(pg_temp.reward_read('legacy')->'definition'->>'reward',null,'Legacy goal has no reward');
select throws_ok($$select public.create_goal_v2(pg_temp.reward_create('missing-reward',null)-'reward')$$,'GL003','invalid_input','v2 requires explicit nullable reward');
select is(public.get_goal_v2(jsonb_build_object('goal_id',md5('missing')::uuid))->>'goal',null,'Missing goal stays null');
select set_config('request.jwt.claims','{"sub":"31000000-0000-4000-8000-000000000002","role":"authenticated"}',true);
select public.initialize_habit_calendar('UTC',1::smallint);
select is(pg_temp.reward_read('reward'),'null'::jsonb,'Another owner cannot read reward');
select is(jsonb_array_length(public.get_goals_v2('{"status":null,"cursor":null}')->'goals'),0,'Other owner list has no private reward');
select throws_ok($$select public.edit_goal_v2(pg_temp.reward_edit('legacy','cross-edit',1,'Forbidden'))$$,'GL004','not_found','Cross-owner edit rejected');
select throws_ok($$select public.create_goal_v2(pg_temp.reward_create('forged',null)||'{"user_id":"31000000-0000-4000-8000-000000000001"}'::jsonb)$$,'GL003','invalid_input','Cannot inject ownership');
select throws_ok($$select private.goal_with_reward('{}', '31000000-0000-4000-8000-000000000001')$$,'42501',null,'Private projection inaccessible');
select set_config('request.jwt.claims','{}',true);
select throws_ok($$select public.get_goal_v2(jsonb_build_object('goal_id',md5('reward')::uuid))$$,'GL001','unauthorized','Missing identity rejected');
reset role;
set local role anon;
select throws_ok($$select public.get_goal_v2('{}')$$,'42501',null,'Anonymous detail denied');
select throws_ok($$select public.get_goals_v2('{}')$$,'42501',null,'Anonymous list denied');
select throws_ok($$select public.create_goal_v2('{}')$$,'42501',null,'Anonymous create denied');
select throws_ok($$select public.edit_goal_v2('{}')$$,'42501',null,'Anonymous edit denied');
reset role;
select * from finish();
rollback;
