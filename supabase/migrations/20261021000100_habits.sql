-- Habit v1: immutable calendar/definitions and transactional day commands.
alter table public.profiles add column week_start_day smallint
  check (week_start_day in (1, 7));
alter table public.profiles add constraint profiles_calendar_complete
  check (week_start_day is null or time_zone is not null);
revoke update (time_zone) on public.profiles from authenticated;

create or replace function private.prepare_profile_update()
returns trigger language plpgsql set search_path = '' as $$
begin
  if old.week_start_day is not null and
    (new.time_zone is distinct from old.time_zone or new.week_start_day is distinct from old.week_start_day) then
    raise exception 'calendar_locked' using errcode = 'HT009';
  end if;
  if new.time_zone is not null and not exists (
    select 1 from pg_catalog.pg_timezone_names where name = new.time_zone
  ) then
    raise exception 'invalid_input' using errcode = 'HT003';
  end if;
  new.updated_at := clock_timestamp();
  return new;
end;
$$;

create table public.habits (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete restrict,
  name text not null check (name = btrim(name) and char_length(name) between 1 and 100),
  start_date date not null,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  unique (id, user_id)
);
create index habits_owner_created on public.habits (user_id, created_at desc, id desc);

create table public.habit_definitions (
  id uuid primary key default gen_random_uuid(),
  habit_id uuid not null unique,
  user_id uuid not null,
  effective_from date not null,
  measurement_mode text not null check (measurement_mode in ('binary', 'quantity')),
  schedule_type text not null check (schedule_type in ('daily', 'weekdays', 'weekly')),
  weekday_mask smallint,
  weekly_target smallint,
  target_milliunits bigint,
  unit_label text,
  time_zone text not null,
  week_start_day smallint not null check (week_start_day in (1, 7)),
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  foreign key (habit_id, user_id) references public.habits(id, user_id) on delete restrict,
  unique (id, habit_id, user_id),
  check ((
    (schedule_type = 'daily' and weekday_mask is null and weekly_target is null) or
    (schedule_type = 'weekdays' and weekday_mask between 1 and 127 and weekly_target is null) or
    (schedule_type = 'weekly' and weekly_target between 1 and 7 and weekday_mask is null)
  ) is true),
  check ((
    (measurement_mode = 'binary' and target_milliunits is null and unit_label is null) or
    (measurement_mode = 'quantity' and target_milliunits between 1 and 999999999999
      and unit_label is not null and unit_label = btrim(unit_label) and char_length(unit_label) between 1 and 30)
  ) is true)
);
create index habit_definitions_owner on public.habit_definitions (user_id);

create table public.habit_day_records (
  habit_id uuid not null,
  user_id uuid not null,
  definition_id uuid not null,
  occurrence_date date not null,
  binary_value boolean,
  amount_milliunits bigint check (amount_milliunits between 0 and 999999999999),
  revision bigint not null check (revision between 1 and 9007199254740991),
  recorded_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  primary key (habit_id, occurrence_date),
  foreign key (definition_id, habit_id, user_id) references public.habit_definitions(id, habit_id, user_id) on delete restrict,
  check ((binary_value is not null and amount_milliunits is null) or
    (binary_value is null and amount_milliunits is not null))
);
create index habit_day_records_owner on public.habit_day_records (user_id, occurrence_date desc);

create table private.habit_day_operations (
  user_id uuid not null,
  operation_id uuid not null,
  habit_id uuid not null,
  request jsonb not null,
  result jsonb not null,
  created_at timestamptz not null default clock_timestamp(),
  primary key (user_id, operation_id),
  foreign key (habit_id, user_id) references public.habits(id, user_id) on delete restrict
);
alter table private.habit_day_operations enable row level security;
revoke all on private.habit_day_operations from public, anon, authenticated, service_role;

alter table public.habits enable row level security;
alter table public.habit_definitions enable row level security;
alter table public.habit_day_records enable row level security;
revoke all on public.habits, public.habit_definitions, public.habit_day_records from public, anon, authenticated, service_role;
grant select on public.habits, public.habit_definitions, public.habit_day_records to authenticated;
create policy habits_read_own on public.habits for select to authenticated
  using ((select auth.uid()) is not null and user_id = (select auth.uid()));
create policy habit_definitions_read_own on public.habit_definitions for select to authenticated
  using ((select auth.uid()) is not null and user_id = (select auth.uid()));
create policy habit_day_records_read_own on public.habit_day_records for select to authenticated
  using ((select auth.uid()) is not null and user_id = (select auth.uid()));

create function private.habit_date_eligible(p_date date, p_start date, p_schedule text, p_mask smallint)
returns boolean language sql immutable set search_path = '' as $$
  select p_date >= p_start and case p_schedule
    when 'daily' then true when 'weekly' then true
    when 'weekdays' then (p_mask::integer & (1 << (extract(isodow from p_date)::integer - 1))) <> 0
    else false end;
$$;
create function private.habit_date_writable(p_date date, p_today date)
returns boolean language sql immutable set search_path = '' as $$
  select p_date between p_today - 7 and p_today;
$$;
revoke all on function private.habit_date_eligible(date, date, text, smallint),
  private.habit_date_writable(date, date) from public, anon, authenticated, service_role;

-- No privileged reads: the profile SELECT policy is used by this RPC.
create function public.get_habit_context()
returns table (server_time timestamptz, business_date date, time_zone text, week_start_day smallint,
  week_start_date date, next_day_at timestamptz)
language plpgsql security invoker set search_path = '' as $$
declare v_profile public.profiles%rowtype; v_now timestamptz := clock_timestamp(); v_day date;
begin
  if auth.uid() is null then raise exception 'unauthorized' using errcode = 'HT001'; end if;
  select * into v_profile from public.profiles where id = auth.uid();
  if not found then raise exception 'not_found' using errcode = 'HT004'; end if;
  if v_profile.week_start_day is not null then v_day := (v_now at time zone v_profile.time_zone)::date; end if;
  return query select v_now, v_day, v_profile.time_zone, v_profile.week_start_day,
    v_day - ((extract(isodow from v_day)::integer - v_profile.week_start_day::integer + 7) % 7),
    (v_day + 1)::timestamp at time zone v_profile.time_zone;
end;
$$;

-- Definer is necessary: clients have no direct calendar UPDATE privilege.
create function public.initialize_habit_calendar(p_time_zone text, p_week_start_day smallint)
returns void language plpgsql security definer set search_path = '' as $$
declare v_user uuid := auth.uid(); v_profile public.profiles%rowtype;
begin
  if v_user is null then raise exception 'unauthorized' using errcode = 'HT001'; end if;
  select * into v_profile from public.profiles where id = v_user for update;
  if not found then raise exception 'not_found' using errcode = 'HT004'; end if;
  if p_time_zone is null or p_week_start_day is null or p_week_start_day not in (1, 7)
    or not exists (select 1 from pg_catalog.pg_timezone_names where name = p_time_zone
      and (strpos(name, '/') > 0 or name = 'UTC')) then
    raise exception 'invalid_input' using errcode = 'HT003';
  end if;
  if v_profile.week_start_day is not null then
    if v_profile.time_zone = p_time_zone and v_profile.week_start_day = p_week_start_day then return; end if;
    raise exception 'calendar_locked' using errcode = 'HT009';
  end if;
  update public.profiles set time_zone = p_time_zone, week_start_day = p_week_start_day where id = v_user;
end;
$$;

create function public.create_habit(p_id uuid, p_name text, p_measurement_mode text, p_schedule_type text,
  p_weekday_mask smallint default null, p_weekly_target smallint default null,
  p_target_milliunits bigint default null, p_unit_label text default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_user uuid := auth.uid(); v_profile public.profiles%rowtype;
  v_habit public.habits%rowtype; v_definition public.habit_definitions%rowtype; v_day date;
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
  select * into v_habit from public.habits where id = p_id;
  if found then
    if v_habit.user_id <> v_user then raise exception 'not_found' using errcode = 'HT004'; end if;
    select * into v_definition from public.habit_definitions where habit_id = p_id;
    if v_habit.name <> btrim(p_name) or v_definition.measurement_mode <> p_measurement_mode
      or v_definition.schedule_type <> p_schedule_type
      or v_definition.weekday_mask is distinct from p_weekday_mask
      or v_definition.weekly_target is distinct from p_weekly_target
      or v_definition.target_milliunits is distinct from p_target_milliunits
      or v_definition.unit_label is distinct from btrim(p_unit_label) then
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
  return p_id;
end;
$$;

create function public.record_habit_day(p_operation_id uuid, p_habit_id uuid, p_occurrence_date date,
  p_kind text, p_binary_value boolean default null, p_amount_milliunits bigint default null,
  p_expected_revision bigint default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_user uuid := auth.uid(); v_habit public.habits%rowtype; v_definition public.habit_definitions%rowtype;
  v_record public.habit_day_records%rowtype; v_operation private.habit_day_operations%rowtype;
  v_request jsonb; v_result jsonb; v_revision bigint; v_amount bigint; v_day date;
begin
  if v_user is null then raise exception 'unauthorized' using errcode = 'HT001'; end if;
  if p_operation_id is null or p_habit_id is null then raise exception 'invalid_input' using errcode = 'HT003'; end if;
  -- Serialize the operation identity even when requests name different habits.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_user::text || p_operation_id::text, 0));
  v_request := jsonb_build_object('habit_id', p_habit_id, 'occurrence_date', p_occurrence_date, 'kind', p_kind,
    'binary_value', p_binary_value, 'amount_milliunits', p_amount_milliunits, 'expected_revision', p_expected_revision);
  select * into v_operation from private.habit_day_operations where user_id = v_user and operation_id = p_operation_id;
  if found then
    if v_operation.request <> v_request then raise exception 'operation_reused' using errcode = 'HT005'; end if;
    return v_operation.result;
  end if;
  select * into v_habit from public.habits where id = p_habit_id and user_id = v_user for update;
  if not found then raise exception 'not_found' using errcode = 'HT004'; end if;
  select * into v_definition from public.habit_definitions where habit_id = p_habit_id and user_id = v_user;
  v_day := (clock_timestamp() at time zone v_definition.time_zone)::date;
  if p_occurrence_date is null or p_kind is null or p_kind not in ('set_binary', 'add_amount', 'set_total') then
    raise exception 'invalid_input' using errcode = 'HT003';
  end if;
  if not private.habit_date_writable(p_occurrence_date, v_day) then
    raise exception 'outside_window' using errcode = 'HT006';
  end if;
  if not private.habit_date_eligible(p_occurrence_date, v_habit.start_date, v_definition.schedule_type, v_definition.weekday_mask) then
    raise exception 'ineligible_date' using errcode = 'HT007';
  end if;
  if p_kind = 'set_binary' then
    if v_definition.measurement_mode <> 'binary' or p_binary_value is null or p_amount_milliunits is not null then
      raise exception 'invalid_input' using errcode = 'HT003';
    end if;
  else
    if v_definition.measurement_mode <> 'quantity' or p_binary_value is not null
      or p_amount_milliunits is null or p_amount_milliunits < 0 or p_amount_milliunits > 999999999999
      or (p_kind = 'add_amount' and p_amount_milliunits = 0) then
      raise exception 'invalid_input' using errcode = 'HT003';
    end if;
  end if;
  select * into v_record from public.habit_day_records where habit_id = p_habit_id and occurrence_date = p_occurrence_date;
  v_revision := coalesce(v_record.revision, 0);
  if p_kind in ('set_binary', 'set_total') then
    if p_expected_revision is null or p_expected_revision <> v_revision then
      raise exception 'revision_conflict' using errcode = 'HT008';
    end if;
  elsif p_expected_revision is not null then raise exception 'invalid_input' using errcode = 'HT003'; end if;
  if p_kind = 'add_amount' then v_amount := coalesce(v_record.amount_milliunits, 0) + p_amount_milliunits;
  elsif p_kind = 'set_total' then v_amount := p_amount_milliunits; end if;
  if v_amount > 999999999999 then raise exception 'amount_limit' using errcode = 'HT010'; end if;
  insert into public.habit_day_records (habit_id, user_id, definition_id, occurrence_date, binary_value, amount_milliunits, revision)
  values (p_habit_id, v_user, v_definition.id, p_occurrence_date, p_binary_value, v_amount, v_revision + 1)
  on conflict (habit_id, occurrence_date) do update
    set binary_value = excluded.binary_value, amount_milliunits = excluded.amount_milliunits,
      revision = excluded.revision, updated_at = clock_timestamp();
  v_result := jsonb_build_object('operation_id', p_operation_id, 'habit_id', p_habit_id,
    'occurrence_date', p_occurrence_date, 'revision', v_revision + 1,
    'binary_value', p_binary_value, 'amount_milliunits', v_amount);
  insert into private.habit_day_operations (user_id, operation_id, habit_id, request, result)
  values (v_user, p_operation_id, p_habit_id, v_request, v_result);
  return v_result;
end;
$$;

revoke all on function public.get_habit_context(), public.initialize_habit_calendar(text, smallint),
  public.create_habit(uuid, text, text, text, smallint, smallint, bigint, text),
  public.record_habit_day(uuid, uuid, date, text, boolean, bigint, bigint)
  from public, anon, authenticated, service_role;
grant execute on function public.get_habit_context(), public.initialize_habit_calendar(text, smallint),
  public.create_habit(uuid, text, text, text, smallint, smallint, bigint, text),
  public.record_habit_day(uuid, uuid, date, text, boolean, bigint, bigint) to authenticated;
comment on table public.habit_day_records is 'Authoritative confirmed day state; immutable operation receipts commit atomically with it.';
comment on table public.habit_definitions is 'Initial immutable definition. Editing, pauses and calendar transitions are deferred.';
