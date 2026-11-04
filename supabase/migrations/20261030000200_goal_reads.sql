-- Coherent goal projections. All helpers are private; public readers authorize first.
create function private.goal_habit_days(p_user uuid,p_habit uuid,p_from date,p_to date)
returns table(occurrence_date date,definition_id uuid,revision bigint,binary_value boolean,amount_milliunits bigint,eligible boolean,completed boolean)
language sql stable set search_path='' as $$
 select r.occurrence_date,d.id,r.revision,r.binary_value,r.amount_milliunits,
  private.habit_date_eligible(r.occurrence_date,h.start_date,d.schedule_type,d.weekday_mask),
  private.habit_date_eligible(r.occurrence_date,h.start_date,d.schedule_type,d.weekday_mask) and
   case d.measurement_mode when 'binary' then coalesce(r.binary_value,false) else coalesce(r.amount_milliunits>=d.target_milliunits,false) end
 from public.habit_day_records r join public.habits h on h.id=r.habit_id and h.user_id=r.user_id
 join lateral(select hd.* from public.habit_definitions hd where hd.habit_id=h.id and hd.user_id=p_user
  and hd.effective_from<=r.occurrence_date order by hd.effective_from desc limit 1) d on true
 where r.user_id=p_user and r.habit_id=p_habit and r.occurrence_date between p_from and p_to
$$;
create function private.project_goal(p_user uuid,p_id uuid,p_today date) returns jsonb
language plpgsql stable set search_path='' as $$
declare g public.goals%rowtype; v public.goal_versions%rowtype; amount numeric:=0; done_count int:=0; total_count int:=0;
 milestones jsonb; states jsonb; definition jsonb; source_value jsonb; progress jsonb; state_value text;
 last_day date; numerator numeric; denominator numeric; percent int;
begin
 select * into g from public.goals where id=p_id and user_id=p_user;
 if not found then return null; end if;
 select * into v from public.goal_versions where goal_id=g.id and user_id=p_user order by version desc limit 1;
 last_day:=least(p_today,coalesce((v.archived_at at time zone g.time_zone)::date,p_today));
 if g.progress_source='habit' then
  select coalesce(sum(case g.linked_metric when 'amount' then case when d.eligible then d.amount_milliunits else 0 end
    else case when d.completed then 1000 else 0 end end),0) into amount
   from private.goal_habit_days(p_user,g.habit_id,g.start_date,last_day) d;
  select jsonb_build_object('habit_id',h.id,'name',h.name,'measurement_mode',d.measurement_mode,
   'linked_metric',g.linked_metric,'unit_label',g.unit_label) into source_value from public.habits h
   join lateral(select hd.measurement_mode from public.habit_definitions hd where hd.habit_id=h.id and hd.user_id=p_user order by effective_from limit 1) d on true
   where h.id=g.habit_id and h.user_id=p_user;
 elsif g.mode='amount' then
  select coalesce(sum(amount_milliunits),0) into amount from public.goal_amount_day_records
   where goal_id=g.id and user_id=p_user and occurrence_date between g.start_date and last_day;
 end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',m.id,'name',m.name,'position',m.position,'threshold_milliunits',m.threshold_milliunits) order by m.position),'[]'),
  count(*) into milestones,total_count from public.goal_milestones m where m.goal_id=g.id and m.user_id=p_user;
 if g.mode='milestones' then
  select coalesce(jsonb_agg(case when g.progress_source='manual' then
    jsonb_build_object('id',m.id,'completed',coalesce(r.completed,false),'completion_date',r.completion_date,'revision',coalesce(r.revision,0))
    else jsonb_build_object('id',m.id,'completed',amount>=m.threshold_milliunits,'threshold_milliunits',m.threshold_milliunits) end order by m.position),'[]'),
   count(*) filter(where case when g.progress_source='manual' then coalesce(r.completed,false) else amount>=m.threshold_milliunits end)
   into states,done_count from public.goal_milestones m
   left join public.goal_milestone_records r on r.milestone_id=m.id and r.goal_id=g.id and r.user_id=p_user
   where m.goal_id=g.id and m.user_id=p_user;
 end if;
 numerator:=case when g.mode='amount' then amount else done_count end;
 denominator:=case when g.mode='amount' then v.target_milliunits else total_count end;
 state_value:=case when v.archived_at is not null then 'archived' when g.start_date>p_today then 'scheduled'
  when numerator>=denominator then 'achieved' when v.deadline<p_today then 'overdue' else 'in_progress' end;
 if amount>999999999999 then
  progress:=jsonb_build_object('available',false,'error','amountLimit','accumulated_milliunits',null,'completed_milestones',null,'total_milestones',null,'percentage',null);
 else
  percent:=least(100,floor(100*numerator/denominator))::int;
  progress:=jsonb_build_object('available',true,'accumulated_milliunits',case when g.mode='amount' or g.progress_source='habit' then amount end,
   'completed_milestones',case when g.mode='milestones' then done_count end,'total_milestones',case when g.mode='milestones' then total_count end,'percentage',percent);
 end if;
 definition:=jsonb_build_object('id',g.id,'name',v.name,'description',v.description,'mode',g.mode,'progress_source',g.progress_source,
  'start_date',g.start_date,'deadline',v.deadline,'time_zone',g.time_zone,'created_at',g.created_at,'updated_at',v.effective_at,
  'archived_at',v.archived_at,'archived_on',(v.archived_at at time zone g.time_zone)::date,'version',v.version,
  'unit_label',g.unit_label,'target_milliunits',v.target_milliunits,'habit_id',g.habit_id,'linked_metric',g.linked_metric,'milestones',milestones);
 return jsonb_build_object('definition',definition,'state',state_value,'progress',progress,'milestone_states',coalesce(states,'[]'),'source',source_value);
end $$;

create function private.read_goals(p_kind text,p_input jsonb) returns jsonb language plpgsql stable set search_path='' as $$
declare
 u uuid:=auth.uid(); ctx jsonb; today date; goal_identity uuid; g public.goals%rowtype; v public.goal_versions%rowtype;
 status_value text; cursor_value jsonb; cursor_id uuid; cursor_time timestamptz; result jsonb; from_day date; to_day date; end_day date;
 upper_seq bigint; before_seq bigint; max_seq bigint;
begin
 ctx:=private.goal_context(u,statement_timestamp()); today:=(ctx->>'today')::date;
 if p_kind='list' then
  perform private.goal_object(p_input,array['status','cursor']);
  if p_input->'status'<>'null'::jsonb then
   status_value:=private.goal_text(p_input->'status',1,20);
   if status_value not in ('archived','scheduled','achieved','overdue','in_progress') then raise exception 'invalid_input' using errcode='GL003'; end if;
  end if;
  if p_input->'cursor'<>'null'::jsonb then
   if jsonb_typeof(p_input->'cursor') is distinct from 'string' or char_length(p_input->>'cursor')>2048 then raise exception 'invalid_input' using errcode='GL003'; end if;
   begin
    cursor_value:=convert_from(decode(p_input->>'cursor','base64'),'UTF8')::jsonb;
    perform private.goal_object(cursor_value,array['format','status','created_at','id']);
    if cursor_value->'format'<>'1'::jsonb or cursor_value->'status' is distinct from p_input->'status' then raise exception 'invalid_input' using errcode='GL003'; end if;
    cursor_id:=private.goal_uuid(cursor_value->'id');
    if jsonb_typeof(cursor_value->'created_at') is distinct from 'string' then raise exception 'invalid_input' using errcode='GL003'; end if;
    cursor_time:=(cursor_value->>'created_at')::timestamptz;
    if not isfinite(cursor_time) then raise exception 'invalid_input' using errcode='GL003'; end if;
   exception when invalid_text_representation or invalid_parameter_value or character_not_in_repertoire or datetime_field_overflow or invalid_datetime_format then
    raise exception 'invalid_input' using errcode='GL003';
   end;
  end if;
  with all_goals as materialized(
   select x.id,x.created_at,private.project_goal(u,x.id,today) as doc from public.goals x where x.user_id=u
  ), filtered as materialized(
   select * from all_goals where (status_value is null or doc->>'state'=status_value)
    and (cursor_id is null or (created_at,id)<(cursor_time,cursor_id))
  ), page as materialized(select * from filtered order by created_at desc,id desc limit 20)
  select jsonb_build_object('context',ctx,'goals',coalesce((select jsonb_agg(doc order by created_at desc,id desc) from page),'[]'),
   'counts',(select jsonb_object_agg(s,(select count(*) from all_goals where doc->>'state'=s))
     from unnest(array['archived','scheduled','achieved','overdue','in_progress']) s),
   'next_cursor',case when (select count(*) from filtered)>20 then
    (select replace(encode(convert_to(jsonb_build_object('format',1,'status',status_value,'created_at',created_at,'id',id)::text,'UTF8'),'base64'),chr(10),'')
      from page order by created_at,id limit 1) end) into result;
  return result;
 end if;
 if p_kind='detail' then
  perform private.goal_object(p_input,array['goal_id']); goal_identity:=private.goal_uuid(p_input->'goal_id');
  return jsonb_build_object('context',ctx,'goal',private.project_goal(u,goal_identity,today));
 end if;
 goal_identity:=private.goal_uuid(p_input->'goal_id');
 select * into g from public.goals where public.goals.id=goal_identity and user_id=u;
 if not found then raise exception 'not_found' using errcode='GL004'; end if;
 if p_kind='contributions' then
  perform private.goal_object(p_input,array['goal_id','from','to']);
  from_day:=private.goal_date(p_input->'from'); to_day:=private.goal_date(p_input->'to');
  if to_day-from_day not between 0 and 30 or (g.mode='milestones' and g.progress_source='manual') then raise exception 'invalid_input' using errcode='GL003'; end if;
  select * into v from public.goal_versions where goal_id=goal_identity and user_id=u order by version desc limit 1;
  end_day:=least(today,coalesce((v.archived_at at time zone g.time_zone)::date,today));
  with dates as(select from_day+n as d from generate_series(0,to_day-from_day) n),
   source_days as materialized(select * from private.goal_habit_days(u,g.habit_id,greatest(from_day,g.start_date),least(to_day,end_day))),
   rows as(
    select d.d, d.d between g.start_date and end_day as in_window,
     case when g.progress_source='manual' then a.revision else h.revision end as revision,
     case when g.progress_source='manual' then a.amount_milliunits else h.amount_milliunits end as amount,
     h.binary_value,h.definition_id,h.eligible,coalesce(h.completed,false) as completed
    from dates d
    left join public.goal_amount_day_records a on g.progress_source='manual' and a.goal_id=g.id and a.user_id=u and a.occurrence_date=d.d and d.d between g.start_date and end_day
    left join source_days h on g.progress_source='habit' and h.occurrence_date=d.d
   )
  select jsonb_build_object('context',ctx,'days',jsonb_agg(jsonb_build_object(
   'date',d,'in_window',in_window,'recorded',in_window and revision is not null,'revision',case when in_window then revision end,
   'amount_milliunits',case when in_window then amount end,'binary_value',case when in_window then binary_value end,
   'source_definition_id',case when in_window then definition_id end,'completed',in_window and completed,
   'contribution_milliunits',case when in_window and revision is not null then
    case when g.progress_source='manual' then amount when g.linked_metric='amount' then case when eligible then amount else 0 end
    else case when completed then 1000 else 0 end end end) order by d)) into result from rows;
  return result;
 elsif p_kind='history' then
  perform private.goal_object(p_input,array['goal_id','before_sequence','up_to_sequence']);
  select max(sequence) into max_seq from private.goal_operations where goal_id=goal_identity and user_id=u;
  if p_input->'up_to_sequence'='null'::jsonb then
   if p_input->'before_sequence'<>'null'::jsonb then raise exception 'invalid_input' using errcode='GL003'; end if;
   upper_seq:=max_seq;
  else upper_seq:=private.goal_int(p_input->'up_to_sequence',1,9007199254740991); end if;
  if p_input->'before_sequence'<>'null'::jsonb then before_seq:=private.goal_int(p_input->'before_sequence',1,upper_seq); end if;
  if upper_seq>max_seq then raise exception 'invalid_input' using errcode='GL003'; end if;
  with events as materialized(
   select * from private.goal_operations where goal_id=goal_identity and user_id=u and sequence<=upper_seq
     and (before_seq is null or sequence<before_seq) order by sequence desc limit 21
  ), page as(select * from events order by sequence desc limit 20)
  select jsonb_build_object('context',ctx,'up_to_sequence',upper_seq,
   'events',coalesce((select jsonb_agg(jsonb_build_object('sequence',sequence,'operation_id',operation_id,'kind',kind,'accepted_at',accepted_at,
      'date',occurrence_date,'before',before_value,'after',after_value) order by sequence desc) from page),'[]'),
   'next_before_sequence',case when (select count(*) from events)>20 then (select min(sequence) from page) end) into result;
  return result;
 end if;
 raise exception 'invalid_input' using errcode='GL003';
end $$;
-- Small authorized definer readers are necessary to access private helpers and safe audit projections.
-- Helpers filter every source by the authenticated owner; no caller-supplied owner is accepted.
create function public.get_goals(p_input jsonb) returns jsonb language sql stable security definer set search_path='' as $$
 select private.read_goals('list',p_input) $$;
create function public.get_goal(p_input jsonb) returns jsonb language sql stable security definer set search_path='' as $$
 select private.read_goals('detail',p_input) $$;
create function public.get_goal_contributions(p_input jsonb) returns jsonb language sql stable security definer set search_path='' as $$
 select private.read_goals('contributions',p_input) $$;
create function public.get_goal_history(p_input jsonb) returns jsonb language sql stable security definer set search_path='' as $$
 select private.read_goals('history',p_input) $$;
revoke all on function public.get_goals(jsonb),public.get_goal(jsonb),public.get_goal_contributions(jsonb),public.get_goal_history(jsonb) from public,anon,authenticated,service_role;
grant execute on function public.get_goals(jsonb),public.get_goal(jsonb),public.get_goal_contributions(jsonb),public.get_goal_history(jsonb) to authenticated;
revoke all on function private.goal_habit_days(uuid,uuid,date,date),private.project_goal(uuid,uuid,date),private.read_goals(text,jsonb) from public,anon,authenticated,service_role;
