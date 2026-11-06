-- Goals v1: private ownership, immutable configuration history and idempotent commands.
create function private.goal_trim(p_text text) returns text language sql immutable set search_path='' as $$
 select btrim(p_text, E' \t\n\r\f' || chr(11)||chr(160)||chr(5760)||
 chr(8192)||chr(8193)||chr(8194)||chr(8195)||chr(8196)||chr(8197)||chr(8198)||
 chr(8199)||chr(8200)||chr(8201)||chr(8202)||chr(8232)||chr(8233)||chr(8239)||chr(8287)||chr(12288)||chr(65279))
$$;
create table public.goals (
 id uuid primary key, user_id uuid not null references auth.users(id) on delete restrict,
 mode text not null check(mode in ('amount','milestones')),
 progress_source text not null check(progress_source in ('manual','habit')),
 start_date date not null, time_zone text not null,
 unit_label text check(unit_label=private.goal_trim(unit_label) and char_length(unit_label) between 1 and 30),
 habit_id uuid, linked_metric text check(linked_metric in ('amount','completed_days')),
 created_at timestamptz not null default clock_timestamp(),
 unique(id,user_id),
 foreign key(habit_id,user_id) references public.habits(id,user_id) on delete restrict,
 check(((progress_source='manual' and habit_id is null and linked_metric is null and
   ((mode='amount' and unit_label is not null) or (mode='milestones' and unit_label is null))) or
  (progress_source='habit' and habit_id is not null and linked_metric is not null and
   ((linked_metric='amount' and unit_label is not null) or (linked_metric='completed_days' and unit_label is null)))) is true)
);
create index goals_owner_created on public.goals(user_id,created_at desc,id desc);
create index goals_habit on public.goals(user_id,habit_id) where habit_id is not null;
create table public.goal_versions (
 goal_id uuid not null, user_id uuid not null, version bigint not null check(version between 1 and 9007199254740991),
 effective_at timestamptz not null default clock_timestamp(),
 name text not null check(name=private.goal_trim(name) and char_length(name) between 1 and 100),
 description text check(description=private.goal_trim(description) and char_length(description) between 1 and 400),
 target_milliunits bigint check(target_milliunits between 1 and 999999999999),
 deadline date, archived_at timestamptz,
 primary key(goal_id,version),
 foreign key(goal_id,user_id) references public.goals(id,user_id) on delete restrict
);
create table public.goal_milestones (
 id uuid primary key, goal_id uuid not null, user_id uuid not null,
 position smallint not null check(position between 0 and 29),
 name text not null check(name=private.goal_trim(name) and char_length(name) between 1 and 100),
 threshold_milliunits bigint check(threshold_milliunits between 1 and 999999999999),
 unique(id,goal_id,user_id), unique(goal_id,position),
 foreign key(goal_id,user_id) references public.goals(id,user_id) on delete restrict
);
create table public.goal_amount_day_records (
 goal_id uuid not null, user_id uuid not null, occurrence_date date not null,
 amount_milliunits bigint not null check(amount_milliunits between 0 and 999999999999),
 revision bigint not null check(revision between 1 and 9007199254740991),
 recorded_at timestamptz not null default clock_timestamp(), updated_at timestamptz not null default clock_timestamp(),
 primary key(goal_id,occurrence_date),
 foreign key(goal_id,user_id) references public.goals(id,user_id) on delete restrict
);
create table public.goal_milestone_records (
 milestone_id uuid primary key, goal_id uuid not null, user_id uuid not null,
 completed boolean not null, completion_date date,
 revision bigint not null check(revision between 1 and 9007199254740991),
 recorded_at timestamptz not null default clock_timestamp(), updated_at timestamptz not null default clock_timestamp(),
 foreign key(milestone_id,goal_id,user_id) references public.goal_milestones(id,goal_id,user_id) on delete restrict,
 check((completed and completion_date is not null) or (not completed and completion_date is null))
);
create table private.goal_operations (
 user_id uuid not null, operation_id uuid not null, goal_id uuid not null,
 sequence bigint not null check(sequence between 1 and 9007199254740991),
 kind text not null check(kind in ('create','edit','archive','amount_add','amount_set','milestone_set')),
 request jsonb not null, result jsonb not null, before_value jsonb, after_value jsonb not null,
 occurrence_date date, accepted_at timestamptz not null,
 primary key(user_id,operation_id), unique(goal_id,sequence),
 foreign key(goal_id,user_id) references public.goals(id,user_id) on delete restrict
);
alter table private.goal_operations enable row level security;
revoke all on private.goal_operations from public,anon,authenticated,service_role;
do $$ declare t text; begin
 foreach t in array array['goals','goal_versions','goal_milestones','goal_amount_day_records','goal_milestone_records'] loop
  execute format('alter table public.%I enable row level security',t);
  execute format('revoke all on public.%I from public,anon,authenticated,service_role',t);
  execute format('grant select on public.%I to authenticated',t);
  execute format('create policy %I on public.%I for select to authenticated using ((select auth.uid()) is not null and user_id=(select auth.uid()))',t||'_read_own',t);
 end loop;
end $$;

create function private.goal_immutable() returns trigger language plpgsql set search_path='' as $$
begin raise exception 'immutable_goal_history' using errcode='GL003'; end $$;
create trigger goal_identity_immutable before update or delete on public.goals for each row execute function private.goal_immutable();
create trigger goal_version_immutable before update or delete on public.goal_versions for each row execute function private.goal_immutable();
create trigger goal_milestone_immutable before update or delete on public.goal_milestones for each row execute function private.goal_immutable();
create trigger goal_operation_immutable before update or delete on private.goal_operations for each row execute function private.goal_immutable();

-- Deferred integrity also protects maintenance writes, not just the mobile RPC.
create function private.check_goal_shape() returns trigger language plpgsql set search_path='' as $$
declare v_id uuid; g public.goals%rowtype; n int; h public.habit_definitions%rowtype;
begin
 if tg_table_name='goals' then v_id:=coalesce(new.id,old.id);
 else v_id:=coalesce(new.goal_id,old.goal_id); end if;
 select * into g from public.goals where id=v_id;
 if not found then return null; end if;
 if not exists(select 1 from pg_catalog.pg_timezone_names where name=g.time_zone) then
  raise exception 'invalid_input' using errcode='GL003'; end if;
 select count(*) into n from public.goal_milestones where goal_id=g.id;
 if (g.mode='amount' and n<>0) or (g.mode='milestones' and
  (n not between 1 and 30 or (select max(position) from public.goal_milestones where goal_id=g.id)<>n-1)) then
  raise exception 'invalid_input' using errcode='GL003'; end if;
 if not exists(select 1 from public.goal_versions where goal_id=g.id and version=1) or exists(
  select 1 from public.goal_versions v where v.goal_id=g.id and
  ((g.mode='amount') is distinct from (v.target_milliunits is not null) or
   v.deadline<g.start_date or (g.linked_metric='completed_days' and v.target_milliunits%1000<>0))
 ) or exists(
  select 1 from public.goal_milestones m where m.goal_id=g.id and
  ((g.progress_source='habit') is distinct from (m.threshold_milliunits is not null) or
    (g.linked_metric='completed_days' and m.threshold_milliunits%1000<>0))
 ) or exists(
  select 1 from public.goal_milestones a join public.goal_milestones b on a.goal_id=b.goal_id and a.position<b.position
  where a.goal_id=g.id and a.threshold_milliunits>=b.threshold_milliunits
 ) then raise exception 'invalid_input' using errcode='GL003'; end if;
 if g.progress_source='habit' then
  select * into h from public.habit_definitions where habit_id=g.habit_id and user_id=g.user_id order by effective_from limit 1;
  if not found or h.time_zone<>g.time_zone or (g.linked_metric='amount' and
   (h.measurement_mode<>'quantity' or h.unit_label is distinct from g.unit_label)) then
   raise exception 'invalid_input' using errcode='GL003'; end if;
 end if;
 if exists(select 1 from public.goal_amount_day_records r where r.goal_id=g.id and
  (g.mode<>'amount' or g.progress_source<>'manual' or r.occurrence_date<g.start_date)) or
  exists(select 1 from public.goal_milestone_records r where r.goal_id=g.id and
   (g.mode<>'milestones' or g.progress_source<>'manual' or r.completion_date<g.start_date)) then
   raise exception 'invalid_input' using errcode='GL003'; end if;
 if (select coalesce(sum(amount_milliunits),0) from public.goal_amount_day_records where goal_id=g.id)>999999999999 then
  raise exception 'amount_limit' using errcode='GL010'; end if;
 return null;
end $$;
do $$ declare t text; begin
 foreach t in array array['goals','goal_versions','goal_milestones','goal_amount_day_records','goal_milestone_records'] loop
  execute format('create constraint trigger %I after insert or update or delete on public.%I deferrable initially deferred for each row execute function private.check_goal_shape()',t||'_shape',t);
 end loop;
end $$;

create function private.goal_object(p jsonb, required text[], optional text[] default '{}') returns void
 language plpgsql immutable set search_path='' as $$
begin
 if jsonb_typeof(p) is distinct from 'object' or not(p ?& required) or exists(
  select 1 from jsonb_object_keys(p) k where not(k=any(required||optional))) then
  raise exception 'invalid_input' using errcode='GL003'; end if;
end $$;
create function private.goal_uuid(p jsonb) returns uuid language plpgsql immutable set search_path='' as $$
begin
 if jsonb_typeof(p) is distinct from 'string' or (p#>>'{}') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
  raise exception 'invalid_input' using errcode='GL003'; end if;
 return (p#>>'{}')::uuid;
end $$;
create function private.goal_int(p jsonb, low bigint default 0, high bigint default 999999999999) returns bigint
language plpgsql immutable set search_path='' as $$
declare n numeric;
begin
 if jsonb_typeof(p) is distinct from 'number' or (p#>>'{}') !~ '^[0-9]+$' then
  raise exception 'invalid_input' using errcode='GL003'; end if;
 n:=(p#>>'{}')::numeric;
 if n<low or n>high then raise exception 'invalid_input' using errcode='GL003'; end if;
 return n::bigint;
end $$;
create function private.goal_text(p jsonb, low int, high int, nullable boolean default false) returns text
language plpgsql immutable set search_path='' as $$
declare v text;
begin
 if nullable and p='null'::jsonb then return null; end if;
 if jsonb_typeof(p) is distinct from 'string' then raise exception 'invalid_input' using errcode='GL003'; end if;
 v:=private.goal_trim(p#>>'{}');
 if nullable and v='' then return null; end if;
 if char_length(v) not between low and high then raise exception 'invalid_input' using errcode='GL003'; end if;
 return v;
end $$;
create function private.goal_date(p jsonb, nullable boolean default false) returns date
language plpgsql immutable set search_path='' as $$
declare d date; v text;
begin
 if nullable and p='null'::jsonb then return null; end if;
 if jsonb_typeof(p) is distinct from 'string' or (p#>>'{}') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
  raise exception 'invalid_input' using errcode='GL003'; end if;
 v:=p#>>'{}';
 begin d:=v::date; exception when datetime_field_overflow or invalid_datetime_format then
  raise exception 'invalid_input' using errcode='GL003'; end;
 if to_char(d,'YYYY-MM-DD')<>v then raise exception 'invalid_input' using errcode='GL003'; end if;
 return d;
end $$;
create function private.goal_context(p_user uuid,p_at timestamptz) returns jsonb
language plpgsql stable set search_path='' as $$
declare p public.profiles%rowtype; d date;
begin
 if p_user is null then raise exception 'unauthorized' using errcode='GL001'; end if;
 select * into p from public.profiles where id=p_user;
 if not found then raise exception 'not_found' using errcode='GL004'; end if;
 if p.week_start_day is null or p.time_zone is null then raise exception 'calendar_required' using errcode='GL002'; end if;
 d:=(p_at at time zone p.time_zone)::date;
 return jsonb_build_object('read_at',p_at,'today',d,'time_zone',p.time_zone,'next_day_at',(d+1)::timestamp at time zone p.time_zone);
end $$;

-- Private dispatcher keeps one transactional implementation; wrappers alone are exposed.
create function private.write_goal(p_kind text,p_input jsonb) returns jsonb
language plpgsql set search_path='' as $$
declare
 u uuid:=auth.uid(); op uuid; goal_identity uuid; norm jsonb; saved private.goal_operations%rowtype;
 g public.goals%rowtype; v public.goal_versions%rowtype; h public.habit_definitions%rowtype;
 m public.goal_milestones%rowtype; amount_row public.goal_amount_day_records%rowtype; milestone_row public.goal_milestone_records%rowtype;
 ctx jsonb; at_time timestamptz; today date; start_day date; deadline_day date; record_day date;
 mode_value text; source_value text; metric text; unit_value text; name_value text; desc_value text;
 target bigint; expected bigint; qty bigint; new_total bigint; rev bigint; seq bigint;
 items jsonb:='[]'; item jsonb; mid uuid; done boolean; action_value text; result_kind text;
 before_value jsonb; after_value jsonb; receipt jsonb; fields text[]; i int:=0; last_threshold bigint:=0;
begin
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
  perform private.goal_object(p_input,array['operation_id','goal_id','expected_version','name','description','deadline','target_milliunits']);
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
  insert into public.goal_versions(goal_id,user_id,version,effective_at,name,description,target_milliunits,deadline)
   values(goal_identity,u,1,at_time,name_value,desc_value,target,deadline_day) returning * into v;
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
    insert into public.goal_versions(goal_id,user_id,version,effective_at,name,description,target_milliunits,deadline)
     values(goal_identity,u,v.version+1,at_time,name_value,desc_value,target,deadline_day) returning * into v;
   else
    insert into public.goal_versions(goal_id,user_id,version,effective_at,name,description,target_milliunits,deadline,archived_at)
     values(goal_identity,u,v.version+1,at_time,v.name,v.description,v.target_milliunits,v.deadline,at_time) returning * into v;
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

create function public.create_goal(p_input jsonb) returns jsonb language sql security definer set search_path='' as $$
 select private.write_goal('create',p_input) $$;
create function public.edit_goal(p_input jsonb) returns jsonb language sql security definer set search_path='' as $$
 select private.write_goal('edit',p_input) $$;
create function public.archive_goal(p_input jsonb) returns jsonb language sql security definer set search_path='' as $$
 select private.write_goal('archive',p_input) $$;
create function public.record_goal_amount(p_input jsonb) returns jsonb language sql security definer set search_path='' as $$
 select private.write_goal('amount',p_input) $$;
create function public.record_goal_milestone(p_input jsonb) returns jsonb language sql security definer set search_path='' as $$
 select private.write_goal('milestone',p_input) $$;
revoke all on function public.create_goal(jsonb), public.edit_goal(jsonb), public.archive_goal(jsonb),
 public.record_goal_amount(jsonb),public.record_goal_milestone(jsonb) from public,anon,authenticated,service_role;
grant execute on function public.create_goal(jsonb),public.edit_goal(jsonb),public.archive_goal(jsonb),
 public.record_goal_amount(jsonb),public.record_goal_milestone(jsonb) to authenticated;
do $$ declare f record; begin
 for f in select p.oid::regprocedure as signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='private' and (p.proname like 'goal_%' or p.proname in ('check_goal_shape','write_goal')) loop
  execute format('revoke all on function %s from public,anon,authenticated,service_role',f.signature);
 end loop;
end $$;
