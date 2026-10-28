-- Routines v1. Additive only: habits and their records remain authoritative.
create table public.routines (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete restrict,
  name text not null check (name = btrim(name) and char_length(name) between 1 and 100),
  start_date date not null,
  archived_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  unique (id, user_id)
);
create index routines_owner_created on public.routines(user_id, created_at desc, id desc);
create table public.routine_definitions (
  id uuid primary key default gen_random_uuid(),
  routine_id uuid not null,
  user_id uuid not null,
  effective_from date not null,
  schedule_type text not null check (schedule_type in ('daily','weekdays')),
  weekday_mask smallint,
  time_zone text not null,
  week_start_day smallint not null check (week_start_day in (1,7)),
  foreign key (routine_id,user_id) references public.routines(id,user_id) on delete restrict,
  unique (id,routine_id,user_id),
  unique (routine_id,effective_from),
  check (((schedule_type='daily' and weekday_mask is null) or
    (schedule_type='weekdays' and weekday_mask between 1 and 127)) is true)
);
create table public.routine_steps (
  id uuid primary key,
  routine_id uuid not null,
  user_id uuid not null,
  step_kind text not null check (step_kind in ('own','habit')),
  habit_id uuid,
  foreign key (routine_id,user_id) references public.routines(id,user_id) on delete restrict,
  foreign key (habit_id,user_id) references public.habits(id,user_id) on delete restrict,
  unique (id,routine_id,user_id),
  check ((step_kind='own' and habit_id is null) or (step_kind='habit' and habit_id is not null))
);
create index routine_steps_habit on public.routine_steps(user_id,habit_id) where habit_id is not null;
create table public.routine_definition_steps (
  definition_id uuid not null,
  routine_id uuid not null,
  step_id uuid not null,
  user_id uuid not null,
  position smallint not null check (position between 0 and 29),
  is_required boolean not null,
  own_title text check (own_title = btrim(own_title) and char_length(own_title) between 1 and 100),
  primary key (definition_id,step_id),
  unique (definition_id,position),
  unique (definition_id,routine_id,step_id,user_id),
  foreign key (definition_id,routine_id,user_id) references public.routine_definitions(id,routine_id,user_id) on delete restrict,
  foreign key (step_id,routine_id,user_id) references public.routine_steps(id,routine_id,user_id) on delete restrict
);
create table public.routine_step_day_records (
  step_id uuid not null,
  routine_id uuid not null,
  definition_id uuid not null,
  user_id uuid not null,
  occurrence_date date not null,
  completed boolean not null,
  revision bigint not null check (revision between 1 and 9007199254740991),
  recorded_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  primary key (step_id,occurrence_date),
  foreign key (definition_id,routine_id,step_id,user_id)
    references public.routine_definition_steps(definition_id,routine_id,step_id,user_id) on delete restrict
);
create index routine_records_window on public.routine_step_day_records(user_id,routine_id,occurrence_date);
create table private.routine_operations (
  user_id uuid not null,
  operation_id uuid not null,
  routine_id uuid not null,
  request jsonb not null,
  result jsonb not null,
  created_at timestamptz not null default clock_timestamp(),
  primary key (user_id,operation_id),
  foreign key (routine_id,user_id) references public.routines(id,user_id) on delete restrict
);
alter table private.routine_operations enable row level security;
revoke all on private.routine_operations from public,anon,authenticated,service_role;
do $$ declare t text; begin
  foreach t in array array['routines','routine_definitions','routine_steps','routine_definition_steps','routine_step_day_records'] loop
    execute format('alter table public.%I enable row level security',t);
    execute format('revoke all on public.%I from public,anon,authenticated,service_role',t);
    execute format('grant select on public.%I to authenticated',t);
    execute format('create policy %I on public.%I for select to authenticated using ((select auth.uid()) is not null and user_id=(select auth.uid()))',t||'_read_own',t);
  end loop;
end $$;

-- Shape constraints work across rows and are checked against the committed definition.
create function private.check_routine_shape() returns trigger language plpgsql set search_path='' as $$
declare v_id uuid; v_count int; v_required int; v_max int;
begin
  if tg_table_name='routine_definitions' then v_id:=coalesce(new.id,old.id);
  else v_id:=coalesce(new.definition_id,old.definition_id); end if;
  if not exists(select 1 from public.routine_definitions where id=v_id) then return null; end if;
  select count(*),count(*) filter(where ds.is_required),max(ds.position)
    into v_count,v_required,v_max from public.routine_definition_steps ds where ds.definition_id=v_id;
  if v_count not between 1 and 30 or v_required=0 or v_max<>v_count-1 or exists(
    select 1 from public.routine_definition_steps ds join public.routine_steps s on s.id=ds.step_id
    where ds.definition_id=v_id and ((s.step_kind='own' and ds.own_title is null) or (s.step_kind='habit' and ds.own_title is not null))
  ) or exists(
    select s.habit_id from public.routine_definition_steps ds join public.routine_steps s on s.id=ds.step_id
    where ds.definition_id=v_id and s.habit_id is not null group by s.habit_id having count(*)>1
  ) then raise exception 'invalid_input' using errcode='RT003'; end if;
  return null;
end $$;
create constraint trigger routine_shape_definition after insert or update on public.routine_definitions
  deferrable initially deferred for each row execute function private.check_routine_shape();
create constraint trigger routine_shape_steps after insert or update or delete on public.routine_definition_steps
  deferrable initially deferred for each row execute function private.check_routine_shape();

create function private.check_routine_record() returns trigger language plpgsql set search_path='' as $$
declare v_def public.routine_definitions%rowtype; v_start date;
begin
  select * into v_def from public.routine_definitions where routine_id=new.routine_id
    and effective_from<=new.occurrence_date order by effective_from desc limit 1;
  select start_date into v_start from public.routines where id=new.routine_id;
  if v_def.id is distinct from new.definition_id or not private.habit_date_eligible(
    new.occurrence_date,v_start,v_def.schedule_type,v_def.weekday_mask) or not exists(
    select 1 from public.routine_steps s where s.id=new.step_id and s.step_kind='own'
  ) then raise exception 'ineligible_date' using errcode='RT007'; end if;
  return new;
end $$;
create trigger routine_record_integrity before insert or update on public.routine_step_day_records
  for each row execute function private.check_routine_record();

create function private.normalize_routine_steps(p_steps jsonb) returns jsonb
language plpgsql set search_path='' as $$
declare v jsonb; v_id uuid; v_habit uuid; v_out jsonb:='[]'::jsonb;
begin
  if jsonb_typeof(p_steps) is distinct from 'array' or jsonb_array_length(p_steps) not between 1 and 30 then
    raise exception 'invalid_input' using errcode='RT003'; end if;
  for v in select value from jsonb_array_elements(p_steps) loop
    if jsonb_typeof(v) is distinct from 'object' or v->>'kind' is null or v->>'kind' not in ('own','habit')
      or jsonb_typeof(v->'required') is distinct from 'boolean' or v->>'id' is null then
      raise exception 'invalid_input' using errcode='RT003'; end if;
    begin
      v_id:=(v->>'id')::uuid;
      v_habit:=nullif(v->>'habit_id','')::uuid;
    exception when invalid_text_representation then raise exception 'invalid_input' using errcode='RT003'; end;
    if (v->>'kind'='own' and (v_habit is not null or char_length(btrim(v->>'title')) not between 1 and 100 or v->>'title' is null))
      or (v->>'kind'='habit' and (v_habit is null or v->>'title' is not null)) then
      raise exception 'invalid_input' using errcode='RT003'; end if;
    v_out:=v_out||jsonb_build_array(jsonb_build_object('id',v_id,'kind',v->>'kind','habit_id',v_habit,
      'title',case when v->>'kind'='own' then btrim(v->>'title') end,'required',(v->>'required')::boolean));
  end loop;
  if not exists(select 1 from jsonb_array_elements(v_out) s where (s->>'required')::boolean)
    or (select count(distinct s->>'id') from jsonb_array_elements(v_out) s)<>jsonb_array_length(v_out)
    or exists(select s->>'habit_id' from jsonb_array_elements(v_out) s where s->>'habit_id' is not null
      group by s->>'habit_id' having count(*)>1) then raise exception 'invalid_input' using errcode='RT003'; end if;
  return v_out;
end $$;

-- Caller locks operation identity, then referenced habits in stable order, then routine.
create function private.validate_routine_links(p_user uuid,p_effective date,p_schedule text,p_mask smallint,p_steps jsonb)
returns void language plpgsql set search_path='' as $$
declare v_habit public.habits%rowtype; v_definition public.habit_definitions%rowtype;
  v jsonb; v_overlap boolean:=false; v_routine_mask int;
begin
  if p_schedule is null or p_schedule not in ('daily','weekdays') or not coalesce(
    (p_schedule='daily' and p_mask is null) or (p_schedule='weekdays' and p_mask between 1 and 127),false)
    then raise exception 'invalid_input' using errcode='RT003'; end if;
  v_routine_mask:=case when p_schedule='daily' then 127 else p_mask end;
  perform 1 from public.habits h where h.user_id=p_user and h.id in(
    select (s->>'habit_id')::uuid from jsonb_array_elements(p_steps) s where s->>'habit_id' is not null
  ) order by h.id for update;
  for v in select value from jsonb_array_elements(p_steps) loop
    if v->>'kind'='own' then
      if (v->>'required')::boolean then v_overlap:=true; end if;
    else
      select * into v_habit from public.habits where id=(v->>'habit_id')::uuid and user_id=p_user;
      if not found then raise exception 'not_found' using errcode='RT004'; end if;
      select * into v_definition from public.habit_definitions where habit_id=v_habit.id
        and effective_from<=p_effective order by effective_from desc limit 1;
      if not found then raise exception 'invalid_input' using errcode='RT003'; end if;
      if (v->>'required')::boolean then
        if v_definition.schedule_type='weekly' then raise exception 'flexible_optional' using errcode='RT011'; end if;
        if (v_routine_mask & case when v_definition.schedule_type='daily' then 127 else v_definition.weekday_mask end)<>0
          then v_overlap:=true; end if;
      end if;
    end if;
  end loop;
  if not v_overlap then raise exception 'no_required_overlap' using errcode='RT012'; end if;
end $$;

create function private.store_routine_steps(p_user uuid,p_routine uuid,p_definition uuid,p_steps jsonb)
returns void language plpgsql set search_path='' as $$
declare v jsonb; v_step public.routine_steps%rowtype; v_position int:=0;
begin
  for v in select value from jsonb_array_elements(p_steps) loop
    select * into v_step from public.routine_steps where id=(v->>'id')::uuid;
    if found then
      if v_step.routine_id<>p_routine or v_step.user_id<>p_user
        or v_step.step_kind<>v->>'kind' or v_step.habit_id is distinct from (v->>'habit_id')::uuid then
        raise exception 'invalid_input' using errcode='RT003'; end if;
    else
      insert into public.routine_steps(id,routine_id,user_id,step_kind,habit_id)
        values((v->>'id')::uuid,p_routine,p_user,v->>'kind',(v->>'habit_id')::uuid);
    end if;
    insert into public.routine_definition_steps(definition_id,routine_id,step_id,user_id,position,is_required,own_title)
      values(p_definition,p_routine,(v->>'id')::uuid,p_user,v_position,(v->>'required')::boolean,v->>'title');
    v_position:=v_position+1;
  end loop;
end $$;

create function public.create_routine(p_id uuid,p_name text,p_schedule_type text,p_steps jsonb,p_weekday_mask smallint default null)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_user uuid:=auth.uid(); v_profile public.profiles%rowtype; v_steps jsonb;
  v_request jsonb; v_old private.routine_operations%rowtype; v_today date; v_def uuid;
begin
  if v_user is null then raise exception 'unauthorized' using errcode='RT001'; end if;
  if p_id is null or p_name is null or char_length(btrim(p_name)) not between 1 and 100 then
    raise exception 'invalid_input' using errcode='RT003'; end if;
  v_steps:=private.normalize_routine_steps(p_steps);
  v_request:=jsonb_build_object('kind','create','name',btrim(p_name),'schedule',p_schedule_type,'mask',p_weekday_mask,'steps',v_steps);
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('routine:'||v_user::text||p_id::text,0));
  select * into v_old from private.routine_operations where user_id=v_user and operation_id=p_id;
  if found then
    if v_old.request<>v_request then raise exception 'operation_reused' using errcode='RT005'; end if;
    return v_old.routine_id;
  end if;
  select * into v_profile from public.profiles where id=v_user;
  if not found then raise exception 'not_found' using errcode='RT004'; end if;
  if v_profile.week_start_day is null then raise exception 'calendar_required' using errcode='RT002'; end if;
  v_today:=(clock_timestamp() at time zone v_profile.time_zone)::date;
  perform private.validate_routine_links(v_user,v_today,p_schedule_type,p_weekday_mask,v_steps);
  -- Recheck after any habit-lock wait that crossed midnight.
  if v_today<>(clock_timestamp() at time zone v_profile.time_zone)::date then
    raise exception 'outside_window' using errcode='RT006'; end if;
  if exists(select 1 from public.routines where id=p_id) then raise exception 'not_found' using errcode='RT004'; end if;
  insert into public.routines(id,user_id,name,start_date) values(p_id,v_user,btrim(p_name),v_today);
  insert into public.routine_definitions(routine_id,user_id,effective_from,schedule_type,weekday_mask,time_zone,week_start_day)
    values(p_id,v_user,v_today,p_schedule_type,p_weekday_mask,v_profile.time_zone,v_profile.week_start_day) returning id into v_def;
  perform private.store_routine_steps(v_user,p_id,v_def,v_steps);
  insert into private.routine_operations(user_id,operation_id,routine_id,request,result)
    values(v_user,p_id,p_id,v_request,to_jsonb(p_id));
  return p_id;
end $$;

create function public.edit_routine(p_operation_id uuid,p_routine_id uuid,p_name text,p_expected_updated_at timestamptz,
  p_schedule_type text default null,p_steps jsonb default null,p_weekday_mask smallint default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_user uuid:=auth.uid(); v_routine public.routines%rowtype; v_base public.routine_definitions%rowtype;
  v_profile public.profiles%rowtype; v_old private.routine_operations%rowtype; v_request jsonb; v_steps jsonb;
  v_today date; v_effective date; v_def uuid; v_result jsonb; v_token timestamptz;
begin
  if v_user is null then raise exception 'unauthorized' using errcode='RT001'; end if;
  if p_operation_id is null or p_routine_id is null or p_name is null or char_length(btrim(p_name)) not between 1 and 100
    or p_expected_updated_at is null then raise exception 'invalid_input' using errcode='RT003'; end if;
  if p_schedule_type is not null then v_steps:=private.normalize_routine_steps(p_steps);
  elsif p_steps is not null or p_weekday_mask is not null then raise exception 'invalid_input' using errcode='RT003'; end if;
  v_request:=jsonb_build_object('kind','edit','routine',p_routine_id,'name',btrim(p_name),'token',p_expected_updated_at,
    'schedule',p_schedule_type,'mask',p_weekday_mask,'steps',v_steps);
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('routine:'||v_user::text||p_operation_id::text,0));
  select * into v_old from private.routine_operations where user_id=v_user and operation_id=p_operation_id;
  if found then
    if v_old.request<>v_request then raise exception 'operation_reused' using errcode='RT005'; end if;
    return v_old.result;
  end if;
  -- Do not reveal another owner's linked resources before authorizing this routine.
  if not exists(select 1 from public.routines where id=p_routine_id and user_id=v_user) then
    raise exception 'not_found' using errcode='RT004'; end if;
  select * into v_profile from public.profiles where id=v_user;
  if v_profile.week_start_day is null then raise exception 'calendar_required' using errcode='RT002'; end if;
  v_today:=(clock_timestamp() at time zone v_profile.time_zone)::date;
  v_effective:=v_today-((extract(isodow from v_today)::int-v_profile.week_start_day::int+7)%7)+7;
  if v_steps is not null then
    perform private.validate_routine_links(v_user,v_effective,p_schedule_type,p_weekday_mask,v_steps);
  end if;
  select * into v_routine from public.routines where id=p_routine_id and user_id=v_user for update;
  if v_routine.updated_at<>p_expected_updated_at then raise exception 'revision_conflict' using errcode='RT008'; end if;
  if v_routine.archived_at is not null then raise exception 'archived' using errcode='RT009'; end if;
  if v_today<>(clock_timestamp() at time zone v_profile.time_zone)::date then
    raise exception 'outside_window' using errcode='RT006'; end if;
  if v_steps is not null then
    select * into v_base from public.routine_definitions where routine_id=p_routine_id order by effective_from limit 1;
    select id into v_def from public.routine_definitions where routine_id=p_routine_id and effective_from=v_effective;
    if v_def is null then
      insert into public.routine_definitions(routine_id,user_id,effective_from,schedule_type,weekday_mask,time_zone,week_start_day)
        values(p_routine_id,v_user,v_effective,p_schedule_type,p_weekday_mask,v_base.time_zone,v_base.week_start_day)
        returning id into v_def;
    else
      delete from public.routine_definition_steps where definition_id=v_def;
      update public.routine_definitions set schedule_type=p_schedule_type,weekday_mask=p_weekday_mask where id=v_def;
    end if;
    perform private.store_routine_steps(v_user,p_routine_id,v_def,v_steps);
  else v_effective:=null; end if;
  v_token:=greatest(clock_timestamp(),v_routine.updated_at+interval '1 microsecond');
  update public.routines set name=btrim(p_name),updated_at=v_token where id=p_routine_id;
  v_result:=jsonb_build_object('operation_id',p_operation_id,'routine_id',p_routine_id,'updated_at',v_token,'effective_from',v_effective);
  insert into private.routine_operations(user_id,operation_id,routine_id,request,result)
    values(v_user,p_operation_id,p_routine_id,v_request,v_result);
  return v_result;
end $$;

create function public.archive_routine(p_operation_id uuid,p_routine_id uuid,p_expected_updated_at timestamptz)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_user uuid:=auth.uid(); v_routine public.routines%rowtype; v_old private.routine_operations%rowtype;
  v_request jsonb; v_result jsonb; v_token timestamptz;
begin
  if v_user is null then raise exception 'unauthorized' using errcode='RT001'; end if;
  if p_operation_id is null or p_routine_id is null or p_expected_updated_at is null then
    raise exception 'invalid_input' using errcode='RT003'; end if;
  v_request:=jsonb_build_object('kind','archive','routine',p_routine_id,'token',p_expected_updated_at);
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('routine:'||v_user::text||p_operation_id::text,0));
  select * into v_old from private.routine_operations where user_id=v_user and operation_id=p_operation_id;
  if found then
    if v_old.request<>v_request then raise exception 'operation_reused' using errcode='RT005'; end if;
    return v_old.result;
  end if;
  select * into v_routine from public.routines where id=p_routine_id and user_id=v_user for update;
  if not found then raise exception 'not_found' using errcode='RT004'; end if;
  if v_routine.updated_at<>p_expected_updated_at then raise exception 'revision_conflict' using errcode='RT008'; end if;
  if v_routine.archived_at is not null then raise exception 'archived' using errcode='RT009'; end if;
  v_token:=greatest(clock_timestamp(),v_routine.updated_at+interval '1 microsecond');
  update public.routines set archived_at=v_token,updated_at=v_token where id=p_routine_id;
  v_result:=jsonb_build_object('operation_id',p_operation_id,'routine_id',p_routine_id,'updated_at',v_token);
  insert into private.routine_operations(user_id,operation_id,routine_id,request,result)
    values(v_user,p_operation_id,p_routine_id,v_request,v_result);
  return v_result;
end $$;

create function public.record_routine_step(p_operation_id uuid,p_routine_id uuid,p_step_id uuid,p_occurrence_date date,
  p_completed boolean,p_expected_revision bigint)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_user uuid:=auth.uid(); v_routine public.routines%rowtype; v_def public.routine_definitions%rowtype;
  v_old private.routine_operations%rowtype; v_request jsonb; v_result jsonb; v_today date; v_revision bigint;
begin
  if v_user is null then raise exception 'unauthorized' using errcode='RT001'; end if;
  if p_operation_id is null or p_routine_id is null or p_step_id is null or p_occurrence_date is null
    or p_completed is null or p_expected_revision is null or p_expected_revision<0 then
    raise exception 'invalid_input' using errcode='RT003'; end if;
  v_request:=jsonb_build_object('kind','record','routine',p_routine_id,'step',p_step_id,'date',p_occurrence_date,
    'completed',p_completed,'revision',p_expected_revision);
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('routine:'||v_user::text||p_operation_id::text,0));
  select * into v_old from private.routine_operations where user_id=v_user and operation_id=p_operation_id;
  if found then
    if v_old.request<>v_request then raise exception 'operation_reused' using errcode='RT005'; end if;
    return v_old.result;
  end if;
  select * into v_routine from public.routines where id=p_routine_id and user_id=v_user for update;
  if not found then raise exception 'not_found' using errcode='RT004'; end if;
  if v_routine.archived_at is not null then raise exception 'archived' using errcode='RT009'; end if;
  select * into v_def from public.routine_definitions where routine_id=p_routine_id order by effective_from limit 1;
  v_today:=(clock_timestamp() at time zone v_def.time_zone)::date;
  if p_occurrence_date<>v_today then raise exception 'outside_window' using errcode='RT006'; end if;
  select * into v_def from public.routine_definitions where routine_id=p_routine_id
    and effective_from<=p_occurrence_date order by effective_from desc limit 1;
  if not private.habit_date_eligible(p_occurrence_date,v_routine.start_date,v_def.schedule_type,v_def.weekday_mask)
    or not exists(select 1 from public.routine_definition_steps ds join public.routine_steps s on s.id=ds.step_id
      where ds.definition_id=v_def.id and s.id=p_step_id and s.step_kind='own')
    then raise exception 'ineligible_date' using errcode='RT007'; end if;
  select revision into v_revision from public.routine_step_day_records where step_id=p_step_id and occurrence_date=p_occurrence_date;
  v_revision:=coalesce(v_revision,0);
  if v_revision<>p_expected_revision then raise exception 'revision_conflict' using errcode='RT008'; end if;
  if v_revision>=9007199254740991 then raise exception 'revision_conflict' using errcode='RT008'; end if;
  insert into public.routine_step_day_records(step_id,routine_id,definition_id,user_id,occurrence_date,completed,revision)
    values(p_step_id,p_routine_id,v_def.id,v_user,p_occurrence_date,p_completed,v_revision+1)
    on conflict(step_id,occurrence_date) do update set completed=excluded.completed,revision=excluded.revision,updated_at=clock_timestamp();
  v_result:=jsonb_build_object('operation_id',p_operation_id,'routine_id',p_routine_id,'step_id',p_step_id,
    'occurrence_date',p_occurrence_date,'completed',p_completed,'revision',v_revision+1);
  insert into private.routine_operations(user_id,operation_id,routine_id,request,result)
    values(v_user,p_operation_id,p_routine_id,v_request,v_result);
  return v_result;
end $$;

-- A single invoker read avoids the REST row cap on nested memberships. RLS still applies.
create function public.get_routines(p_ids uuid[] default null,p_offset integer default 0,p_archived boolean default false)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare v_rows jsonb;
begin
  if auth.uid() is null then raise exception 'unauthorized' using errcode='RT001'; end if;
  if p_offset is null or p_offset<0 or p_archived is null
    or (p_ids is not null and cardinality(p_ids) not between 1 and 20) then
    raise exception 'invalid_input' using errcode='RT003'; end if;
  select coalesce(jsonb_agg(t.body order by t.created_at desc,t.id desc),'[]'::jsonb) into v_rows from(
    select r.id,r.created_at,to_jsonb(r)||jsonb_build_object('definitions',(
      select jsonb_agg(to_jsonb(d)||jsonb_build_object('steps',(
        select jsonb_agg(jsonb_build_object('id',s.id,'kind',s.step_kind,'habit_id',s.habit_id,
          'title',ds.own_title,'required',ds.is_required,'position',ds.position) order by ds.position)
        from public.routine_definition_steps ds join public.routine_steps s on s.id=ds.step_id
        where ds.definition_id=d.id
      )) order by d.effective_from) from public.routine_definitions d where d.routine_id=r.id
    )) as body
    from public.routines r where r.user_id=auth.uid() and
      ((p_ids is not null and r.id=any(p_ids)) or (p_ids is null and (r.archived_at is not null)=p_archived))
    order by r.created_at desc,r.id desc offset p_offset limit 21
  ) t;
  return jsonb_build_object('routines',coalesce((select jsonb_agg(value order by ordinality)
    from jsonb_array_elements(v_rows) with ordinality where ordinality<=20),'[]'::jsonb),
    'has_more',jsonb_array_length(v_rows)>20);
end $$;

revoke all on function private.check_routine_shape(),private.check_routine_record(),
  private.normalize_routine_steps(jsonb),private.validate_routine_links(uuid,date,text,smallint,jsonb),
  private.store_routine_steps(uuid,uuid,uuid,jsonb) from public,anon,authenticated,service_role;
revoke all on function public.create_routine(uuid,text,text,jsonb,smallint),
  public.edit_routine(uuid,uuid,text,timestamptz,text,jsonb,smallint),
  public.archive_routine(uuid,uuid,timestamptz),
  public.record_routine_step(uuid,uuid,uuid,date,boolean,bigint),
  public.get_routines(uuid[],integer,boolean) from public,anon,authenticated,service_role;
grant execute on function public.create_routine(uuid,text,text,jsonb,smallint),
  public.edit_routine(uuid,uuid,text,timestamptz,text,jsonb,smallint),
  public.archive_routine(uuid,uuid,timestamptz),
  public.record_routine_step(uuid,uuid,uuid,date,boolean,bigint),
  public.get_routines(uuid[],integer,boolean) to authenticated;
comment on table public.routine_step_day_records is 'Own steps only. Linked habits retain their sole authoritative habit_day_records.';
