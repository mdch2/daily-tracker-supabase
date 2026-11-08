-- Optional personal reward belongs to versioned goal configuration.
-- Existing operations, readers and request fingerprints retain their v1 contract.
alter table public.goal_versions add column reward text
 check (reward = private.goal_trim(reward) and char_length(reward) between 1 and 400);

create or replace function private.write_goal(p_kind text,p_input jsonb) returns jsonb
language plpgsql set search_path='' as $$
declare
 u uuid:=auth.uid(); op uuid; goal_identity uuid; norm jsonb; saved private.goal_operations%rowtype;
 g public.goals%rowtype; v public.goal_versions%rowtype; h public.habit_definitions%rowtype;
 m public.goal_milestones%rowtype; amount_row public.goal_amount_day_records%rowtype; milestone_row public.goal_milestone_records%rowtype;
 ctx jsonb; at_time timestamptz; today date; start_day date; deadline_day date; record_day date;
 reward_value text; with_reward boolean := p_kind in ('create_v2','edit_v2');
 mode_value text; source_value text; metric text; unit_value text; name_value text; desc_value text;
 target bigint; expected bigint; qty bigint; new_total bigint; rev bigint; seq bigint;
 items jsonb:='[]'; item jsonb; mid uuid; done boolean; action_value text; result_kind text;
 before_value jsonb; after_value jsonb; receipt jsonb; fields text[]; i int:=0; last_threshold bigint:=0;
begin
 if with_reward then p_kind:=replace(p_kind,'_v2',''); end if;
 if u is null then raise exception 'unauthorized' using errcode='GL001'; end if;
 -- Establish identity/types before locking; unknown fields cannot smuggle ownership.
 op:=private.goal_uuid(p_input->'operation_id'); goal_identity:=private.goal_uuid(p_input->'goal_id');
 if p_kind='create' then
  mode_value:=private.goal_text(p_input->'mode',1,20); source_value:=private.goal_text(p_input->'progress_source',1,20);
  if mode_value not in ('amount','milestones') or source_value not in ('manual','habit') then
   raise exception 'invalid_input' using errcode='GL003'; end if;
  fields:=array['operation_id','goal_id','name','description','start_date','deadline','mode','progress_source'];
  if mode_value='amount' then fields:=fields||array['target_milliunits']; else fields:=fields||array['milestones']; end if;
  if source_value='habit' then fields:=fields||array['habit_id','linked_metric'];
  elsif mode_value='amount' then fields:=fields||array['unit_label']; end if;
  if with_reward then fields:=fields||array['reward']; end if;
  perform private.goal_object(p_input,fields);
  name_value:=private.goal_text(p_input->'name',1,100); desc_value:=private.goal_text(p_input->'description',0,400,true);
  start_day:=private.goal_date(p_input->'start_date'); deadline_day:=private.goal_date(p_input->'deadline',true);
  if deadline_day<start_day then raise exception 'invalid_input' using errcode='GL003'; end if;
  if mode_value='amount' then target:=private.goal_int(p_input->'target_milliunits',1); end if;
  if source_value='habit' then
   mid:=private.goal_uuid(p_input->'habit_id'); metric:=private.goal_text(p_input->'linked_metric',1,30);
   if metric not in ('amount','completed_days') or (metric='completed_days' and target%1000<>0) then
    raise exception 'invalid_input' using errcode='GL003'; end if;
  elsif mode_value='amount' then unit_value:=private.goal_text(p_input->'unit_label',1,30); end if;
  if mode_value='milestones' then
   if jsonb_typeof(p_input->'milestones') is distinct from 'array' or jsonb_array_length(p_input->'milestones') not between 1 and 30 then
    raise exception 'invalid_input' using errcode='GL003'; end if;
   for item in select value from jsonb_array_elements(p_input->'milestones') loop
    perform private.goal_object(item,case when source_value='habit' then array['id','name','threshold_milliunits'] else array['id','name'] end);
    qty:=null;
    if source_value='habit' then
     qty:=private.goal_int(item->'threshold_milliunits',1);
     if qty<=last_threshold or (metric='completed_days' and qty%1000<>0) then raise exception 'invalid_input' using errcode='GL003'; end if;
     last_threshold:=qty;
    end if;
    items:=items||jsonb_build_array(jsonb_build_object('id',private.goal_uuid(item->'id'),'name',private.goal_text(item->'name',1,100),'threshold_milliunits',qty));
   end loop;
   if (select count(distinct value->>'id') from jsonb_array_elements(items))<>jsonb_array_length(items) then
    raise exception 'invalid_input' using errcode='GL003'; end if;
  end if;
  norm:=jsonb_build_object('kind','create','goal_id',goal_identity,'name',name_value,'description',desc_value,'start_date',start_day,'deadline',deadline_day,
   'mode',mode_value,'progress_source',source_value,'target_milliunits',target,'unit_label',unit_value,'habit_id',mid,'linked_metric',metric,'milestones',items);
  result_kind:='create';
 elsif p_kind='edit' then
  perform private.goal_object(p_input,array['operation_id','goal_id','expected_version','name','description','deadline','target_milliunits'] || case when with_reward then array['reward'] else array[]::text[] end);
  expected:=private.goal_int(p_input->'expected_version',1,9007199254740991);
  name_value:=private.goal_text(p_input->'name',1,100); desc_value:=private.goal_text(p_input->'description',0,400,true);
  deadline_day:=private.goal_date(p_input->'deadline',true);
  if p_input->'target_milliunits'<>'null'::jsonb then target:=private.goal_int(p_input->'target_milliunits',1); end if;
  norm:=jsonb_build_object('kind','edit','goal_id',goal_identity,'expected_version',expected,'name',name_value,'description',desc_value,'deadline',deadline_day,'target_milliunits',target);
  result_kind:='edit';
 elsif p_kind='archive' then
  perform private.goal_object(p_input,array['operation_id','goal_id','expected_version']);
  expected:=private.goal_int(p_input->'expected_version',1,9007199254740991);
  norm:=jsonb_build_object('kind','archive','goal_id',goal_identity,'expected_version',expected); result_kind:='archive';
 elsif p_kind='amount' then
  action_value:=private.goal_text(p_input->'action',1,10);
  if action_value not in ('add','set') then raise exception 'invalid_input' using errcode='GL003'; end if;
  perform private.goal_object(p_input,array['operation_id','goal_id','date','action','amount_milliunits']||
   case when action_value='set' then array['expected_revision'] else array[]::text[] end);
  record_day:=private.goal_date(p_input->'date');
  qty:=private.goal_int(p_input->'amount_milliunits',case when action_value='add' then 1 else 0 end);
  if action_value='set' then expected:=private.goal_int(p_input->'expected_revision',0,9007199254740991); end if;
  result_kind:='amount_'||action_value;
  norm:=jsonb_build_object('kind',result_kind,'goal_id',goal_identity,'date',record_day,'amount_milliunits',qty,'expected_revision',expected);
 elsif p_kind='milestone' then
  perform private.goal_object(p_input,array['operation_id','goal_id','milestone_id','completed','completion_date','expected_revision']);
  mid:=private.goal_uuid(p_input->'milestone_id'); expected:=private.goal_int(p_input->'expected_revision',0,9007199254740991);
  if jsonb_typeof(p_input->'completed') is distinct from 'boolean' then raise exception 'invalid_input' using errcode='GL003'; end if;
  done:=(p_input->>'completed')::boolean; record_day:=private.goal_date(p_input->'completion_date',true);
  if done is distinct from (record_day is not null) then raise exception 'invalid_input' using errcode='GL003'; end if;
  result_kind:='milestone_set';
  norm:=jsonb_build_object('kind',result_kind,'goal_id',goal_identity,'milestone_id',mid,'completed',done,'completion_date',record_day,'expected_revision',expected);
 else raise exception 'invalid_input' using errcode='GL003'; end if;

 if with_reward then
  reward_value:=private.goal_text(p_input->'reward',0,400,true);
  norm:=norm||jsonb_build_object('reward',reward_value);
 end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('goal_op:'||u::text||op::text,0));
 select * into saved from private.goal_operations where user_id=u and operation_id=op;
 if found then
  if saved.request<>norm then raise exception 'operation_reused' using errcode='GL005'; end if;
  return saved.result;
 end if;
 if p_kind='create' then
  -- New entities are serialized too; the habit is locked before the goal.
  if source_value='habit' then
   perform 1 from public.habits where public.habits.id=mid and user_id=u for share;
   if not found then raise exception 'not_found' using errcode='GL004'; end if;
   select * into h from public.habit_definitions where habit_id=mid and user_id=u order by effective_from limit 1;
   if metric='amount' then
    if h.measurement_mode<>'quantity' then raise exception 'invalid_input' using errcode='GL003'; end if;
    unit_value:=h.unit_label;
   end if;
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('goal_entity:'||goal_identity::text,0));
  select * into g from public.goals where public.goals.id=goal_identity;
  if found then
   if g.user_id<>u then raise exception 'not_found' using errcode='GL004'; end if;
   raise exception 'revision_conflict' using errcode='GL008';
  end if;
  at_time:=clock_timestamp(); ctx:=private.goal_context(u,at_time); today:=(ctx->>'today')::date;
  if start_day<today then raise exception 'ineligible_date' using errcode='GL007'; end if;
  if source_value='habit' and h.time_zone<>ctx->>'time_zone' then raise exception 'invalid_input' using errcode='GL003'; end if;
  insert into public.goals(id,user_id,mode,progress_source,start_date,time_zone,unit_label,habit_id,linked_metric,created_at)
   values(goal_identity,u,mode_value,source_value,start_day,ctx->>'time_zone',unit_value,mid,metric,at_time) returning * into g;
  insert into public.goal_versions(goal_id,user_id,version,effective_at,name,description,reward,target_milliunits,deadline)
   values(goal_identity,u,1,at_time,name_value,desc_value,reward_value,target,deadline_day) returning * into v;
  for item in select value from jsonb_array_elements(items) loop
   if exists(select 1 from public.goal_milestones where public.goal_milestones.id=(item->>'id')::uuid) then raise exception 'invalid_input' using errcode='GL003'; end if;
   insert into public.goal_milestones(id,goal_id,user_id,position,name,threshold_milliunits)
    values((item->>'id')::uuid,goal_identity,u,i,item->>'name',(item->>'threshold_milliunits')::bigint);
   i:=i+1;
  end loop;
  after_value:=norm-'kind'; before_value:=null;
 else
  select * into g from public.goals where public.goals.id=goal_identity and user_id=u for update;
  if not found then raise exception 'not_found' using errcode='GL004'; end if;
  select * into v from public.goal_versions where goal_id=goal_identity order by version desc limit 1;
  at_time:=clock_timestamp(); ctx:=private.goal_context(u,at_time); today:=(ctx->>'today')::date;
  if v.archived_at is not null then raise exception 'archived' using errcode='GL009'; end if;
  if p_kind in ('edit','archive') then
   if expected<>v.version then raise exception 'revision_conflict' using errcode='GL008'; end if;
   before_value:=to_jsonb(v)-'user_id'-'goal_id';
   if p_kind='edit' then
    if deadline_day<g.start_date or (g.mode='amount') is distinct from (target is not null) or
      (g.linked_metric='completed_days' and target%1000<>0) then raise exception 'invalid_input' using errcode='GL003'; end if;
    insert into public.goal_versions(goal_id,user_id,version,effective_at,name,description,reward,target_milliunits,deadline)
     values(goal_identity,u,v.version+1,at_time,name_value,desc_value,case when with_reward then reward_value else v.reward end,target,deadline_day) returning * into v;
   else
    insert into public.goal_versions(goal_id,user_id,version,effective_at,name,description,reward,target_milliunits,deadline,archived_at)
     values(goal_identity,u,v.version+1,at_time,v.name,v.description,v.reward,v.target_milliunits,v.deadline,at_time) returning * into v;
   end if;
   after_value:=to_jsonb(v)-'user_id'-'goal_id';
  elsif p_kind='amount' then
   if g.mode<>'amount' or g.progress_source<>'manual' then raise exception 'invalid_input' using errcode='GL003'; end if;
   if record_day<g.start_date or record_day>today then raise exception 'ineligible_date' using errcode='GL007'; end if;
   if record_day<today-7 then raise exception 'outside_window' using errcode='GL006'; end if;
   select * into amount_row from public.goal_amount_day_records where goal_id=goal_identity and occurrence_date=record_day;
   rev:=coalesce(amount_row.revision,0);
   if action_value='set' and rev<>expected then raise exception 'revision_conflict' using errcode='GL008'; end if;
   new_total:=case when action_value='add' then coalesce(amount_row.amount_milliunits,0)+qty else qty end;
   if new_total>999999999999 or (select coalesce(sum(amount_milliunits),0) from public.goal_amount_day_records where goal_id=goal_identity and occurrence_date<>record_day)+new_total>999999999999 then
    raise exception 'amount_limit' using errcode='GL010'; end if;
   before_value:=case when rev=0 then null else jsonb_build_object('amount_milliunits',amount_row.amount_milliunits,'revision',rev) end;
   insert into public.goal_amount_day_records(goal_id,user_id,occurrence_date,amount_milliunits,revision,recorded_at,updated_at)
    values(goal_identity,u,record_day,new_total,rev+1,at_time,at_time)
    on conflict(goal_id,occurrence_date) do update set amount_milliunits=excluded.amount_milliunits,revision=excluded.revision,updated_at=excluded.updated_at;
   after_value:=jsonb_build_object('date',record_day,'amount_milliunits',new_total,'revision',rev+1);
  else
   if g.mode<>'milestones' or g.progress_source<>'manual' then raise exception 'invalid_input' using errcode='GL003'; end if;
   if record_day<g.start_date or record_day>today then raise exception 'ineligible_date' using errcode='GL007'; end if;
   select * into m from public.goal_milestones where public.goal_milestones.id=mid and goal_id=goal_identity and user_id=u;
   if not found then raise exception 'not_found' using errcode='GL004'; end if;
   select * into milestone_row from public.goal_milestone_records where milestone_id=mid and goal_id=goal_identity;
   rev:=coalesce(milestone_row.revision,0);
   if rev<>expected then raise exception 'revision_conflict' using errcode='GL008'; end if;
   before_value:=case when rev=0 then null else jsonb_build_object('completed',milestone_row.completed,'completion_date',milestone_row.completion_date,'revision',rev) end;
   insert into public.goal_milestone_records(milestone_id,goal_id,user_id,completed,completion_date,revision,recorded_at,updated_at)
    values(mid,goal_identity,u,done,record_day,rev+1,at_time,at_time)
    on conflict(milestone_id) do update set completed=excluded.completed,completion_date=excluded.completion_date,revision=excluded.revision,updated_at=excluded.updated_at;
   after_value:=jsonb_build_object('milestone_id',mid,'completed',done,'completion_date',record_day,'revision',rev+1);
  end if;
 end if;
 select coalesce(max(sequence),0)+1 into seq from private.goal_operations where goal_id=goal_identity;
 receipt:=jsonb_build_object('operation_id',op,'goal_id',goal_identity,'kind',result_kind,'accepted_at',at_time,'goal_version',v.version,'event_sequence',seq);
 if p_kind in ('amount','milestone') then receipt:=receipt||after_value;
 elsif p_kind='archive' then receipt:=receipt||jsonb_build_object('archived_at',v.archived_at,'archived_on',(v.archived_at at time zone g.time_zone)::date); end if;
 insert into private.goal_operations(user_id,operation_id,goal_id,sequence,kind,request,result,before_value,after_value,occurrence_date,accepted_at)
  values(u,op,goal_identity,seq,result_kind,norm,receipt,before_value,after_value,record_day,at_time);
 return receipt;
end $$;


create function public.create_goal_v2(p_input jsonb) returns jsonb language sql security definer set search_path='' as $$
 select private.write_goal('create_v2',p_input) $$;
create function public.edit_goal_v2(p_input jsonb) returns jsonb language sql security definer set search_path='' as $$
 select private.write_goal('edit_v2',p_input) $$;

-- Enrich only versioned readers. v1 strict clients must never receive the new key.
create function private.goal_with_reward(p_goal jsonb,p_user uuid) returns jsonb
language sql stable set search_path='' as $$
 select case when p_goal is null or p_goal='null'::jsonb then null else
  jsonb_set(p_goal,'{definition,reward}',coalesce((
   select to_jsonb(v.reward) from public.goal_versions v
   where v.goal_id=(p_goal->'definition'->>'id')::uuid and v.user_id=p_user
   order by v.version desc limit 1
  ),'null'::jsonb)) end $$;
create function public.get_goal_v2(p_input jsonb) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 result:=private.read_goals('detail',p_input);
 return jsonb_set(result,'{goal}',coalesce(private.goal_with_reward(result->'goal',auth.uid()),'null'::jsonb));
end $$;
create function public.get_goals_v2(p_input jsonb) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 result:=private.read_goals('list',p_input);
 return jsonb_set(result,'{goals}',coalesce((
  select jsonb_agg(private.goal_with_reward(entry.value,auth.uid()) order by entry.ordinality)
  from jsonb_array_elements(result->'goals') with ordinality as entry(value,ordinality)
 ),'[]'::jsonb));
end $$;
revoke all on function private.write_goal(text,jsonb),private.goal_with_reward(jsonb,uuid) from public,anon,authenticated,service_role;
revoke all on function public.create_goal_v2(jsonb),public.edit_goal_v2(jsonb),public.get_goal_v2(jsonb),public.get_goals_v2(jsonb) from public,anon,authenticated,service_role;
grant execute on function public.create_goal_v2(jsonb),public.edit_goal_v2(jsonb),public.get_goal_v2(jsonb),public.get_goals_v2(jsonb) to authenticated;
