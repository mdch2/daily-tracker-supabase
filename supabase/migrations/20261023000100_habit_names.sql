-- Names are editable metadata; definitions and historical records remain unchanged.
-- Preserve the original creation payload when a later rename changes habits.name.
create table private.habit_creation_requests (
  habit_id uuid primary key,
  user_id uuid not null,
  request jsonb not null,
  foreign key (habit_id, user_id) references public.habits(id, user_id) on delete restrict
);
alter table private.habit_creation_requests enable row level security;
revoke all on private.habit_creation_requests from public, anon, authenticated, service_role;
insert into private.habit_creation_requests (habit_id, user_id, request)
select h.id, h.user_id, jsonb_build_object('name', h.name, 'measurement_mode', d.measurement_mode,
  'schedule_type', d.schedule_type, 'weekday_mask', d.weekday_mask, 'weekly_target', d.weekly_target,
  'target_milliunits', d.target_milliunits, 'unit_label', d.unit_label)
from public.habits h join public.habit_definitions d on d.habit_id = h.id;

create table private.habit_edit_operations (
  user_id uuid not null,
  operation_id uuid not null,
  habit_id uuid not null,
  request jsonb not null,
  result jsonb not null,
  created_at timestamptz not null default clock_timestamp(),
  primary key (user_id, operation_id),
  foreign key (habit_id, user_id) references public.habits(id, user_id) on delete restrict
);
alter table private.habit_edit_operations enable row level security;
revoke all on private.habit_edit_operations from public, anon, authenticated, service_role;

create or replace function public.create_habit(p_id uuid, p_name text, p_measurement_mode text, p_schedule_type text,
  p_weekday_mask smallint default null, p_weekly_target smallint default null,
  p_target_milliunits bigint default null, p_unit_label text default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_user uuid := auth.uid(); v_profile public.profiles%rowtype;
  v_habit public.habits%rowtype; v_definition public.habit_definitions%rowtype; v_day date; v_request jsonb;
begin
  if v_user is null then raise exception 'unauthorized' using errcode = 'HT001'; end if;
  select * into v_profile from public.profiles where id = v_user for update;
  if not found then raise exception 'not_found' using errcode = 'HT004'; end if;
  if v_profile.week_start_day is null then raise exception 'calendar_required' using errcode = 'HT002'; end if;
  if p_id is null or p_name is null or char_length(btrim(p_name)) not between 1 and 100
    or p_measurement_mode is null or p_measurement_mode not in ('binary', 'quantity')
    or p_schedule_type is null or p_schedule_type not in ('daily', 'weekdays', 'weekly') then
    raise exception 'invalid_input' using errcode = 'HT003';
  end if;
  if not coalesce(case p_schedule_type
      when 'daily' then p_weekday_mask is null and p_weekly_target is null
      when 'weekdays' then p_weekday_mask between 1 and 127 and p_weekly_target is null
      when 'weekly' then p_weekly_target between 1 and 7 and p_weekday_mask is null end, false)
    or not coalesce(case p_measurement_mode
      when 'binary' then p_target_milliunits is null and p_unit_label is null
      when 'quantity' then p_target_milliunits between 1 and 999999999999
        and char_length(btrim(p_unit_label)) between 1 and 30 end, false) then
    raise exception 'invalid_input' using errcode = 'HT003';
  end if;
  v_request := jsonb_build_object('name', btrim(p_name), 'measurement_mode', p_measurement_mode, 'schedule_type', p_schedule_type,
    'weekday_mask', p_weekday_mask, 'weekly_target', p_weekly_target, 'target_milliunits', p_target_milliunits, 'unit_label', btrim(p_unit_label));
  select * into v_habit from public.habits where id = p_id;
  if found then
    if v_habit.user_id <> v_user then raise exception 'not_found' using errcode = 'HT004'; end if;
    if not exists (select 1 from private.habit_creation_requests where habit_id = p_id and user_id = v_user and request = v_request) then
      raise exception 'operation_reused' using errcode = 'HT005';
    end if;
    return p_id;
  end if;
  v_day := (clock_timestamp() at time zone v_profile.time_zone)::date;
  insert into public.habits (id, user_id, name, start_date) values (p_id, v_user, btrim(p_name), v_day);
  insert into public.habit_definitions (habit_id, user_id, effective_from, measurement_mode, schedule_type,
    weekday_mask, weekly_target, target_milliunits, unit_label, time_zone, week_start_day)
  values (p_id, v_user, v_day, p_measurement_mode, p_schedule_type, p_weekday_mask, p_weekly_target,
    p_target_milliunits, btrim(p_unit_label), v_profile.time_zone, v_profile.week_start_day);
  insert into private.habit_creation_requests (habit_id, user_id, request) values (p_id, v_user, v_request);
  return p_id;
end;
$$;

create function public.rename_habit(p_operation_id uuid, p_habit_id uuid, p_name text, p_expected_updated_at timestamptz)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_user uuid := auth.uid(); v_habit public.habits%rowtype;
  v_operation private.habit_edit_operations%rowtype; v_request jsonb; v_result jsonb;
begin
  if v_user is null then raise exception 'unauthorized' using errcode = 'HT001'; end if;
  if p_operation_id is null or p_habit_id is null or p_name is null
    or char_length(btrim(p_name)) not between 1 and 100 or p_expected_updated_at is null then
    raise exception 'invalid_input' using errcode = 'HT003';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_user::text || p_operation_id::text, 0));
  v_request := jsonb_build_object('kind', 'rename', 'habit_id', p_habit_id,
    'name', btrim(p_name), 'expected_updated_at', p_expected_updated_at);
  select * into v_operation from private.habit_edit_operations where user_id = v_user and operation_id = p_operation_id;
  if found then
    if v_operation.request <> v_request then raise exception 'operation_reused' using errcode = 'HT005'; end if;
    return v_operation.result;
  end if;
  select * into v_habit from public.habits where id = p_habit_id and user_id = v_user for update;
  if not found then raise exception 'not_found' using errcode = 'HT004'; end if;
  if v_habit.updated_at <> p_expected_updated_at then
    raise exception 'revision_conflict' using errcode = 'HT008';
  end if;
  update public.habits set name = btrim(p_name),
    updated_at = greatest(clock_timestamp(), v_habit.updated_at + interval '1 microsecond')
    where id = p_habit_id returning * into v_habit;
  v_result := jsonb_build_object('operation_id', p_operation_id, 'habit_id', p_habit_id, 'updated_at', v_habit.updated_at);
  insert into private.habit_edit_operations (user_id, operation_id, habit_id, request, result)
    values (v_user, p_operation_id, p_habit_id, v_request, v_result);
  return v_result;
end;
$$;
revoke all on function public.rename_habit(uuid, uuid, text, timestamptz) from public, anon, authenticated, service_role;
grant execute on function public.rename_habit(uuid, uuid, text, timestamptz) to authenticated;

