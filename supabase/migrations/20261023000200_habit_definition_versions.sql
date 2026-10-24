-- New configuration starts at the next account-week boundary; past versions remain.
alter table public.habit_definitions drop constraint habit_definitions_habit_id_key;
alter table public.habit_definitions add constraint habit_definitions_habit_effective_key unique (habit_id, effective_from);

create function public.edit_habit(p_operation_id uuid, p_habit_id uuid, p_name text, p_expected_updated_at timestamptz,
 p_schedule_type text, p_weekday_mask smallint default null, p_weekly_target smallint default null,
 p_target_milliunits bigint default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_user uuid := auth.uid(); v_habit public.habits%rowtype; v_definition public.habit_definitions%rowtype;
 v_operation private.habit_edit_operations%rowtype; v_request jsonb; v_result jsonb; v_today date; v_effective date;
begin
 if v_user is null then raise exception 'unauthorized' using errcode = 'HT001'; end if;
 if p_operation_id is null or p_habit_id is null or p_name is null or char_length(btrim(p_name)) not between 1 and 100
   or p_expected_updated_at is null or p_schedule_type is null or p_schedule_type not in ('daily','weekdays','weekly') then
   raise exception 'invalid_input' using errcode = 'HT003';
 end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_user::text || p_operation_id::text, 0));
 v_request := jsonb_build_object('kind','edit','habit_id',p_habit_id,'name',btrim(p_name),
  'expected_updated_at',p_expected_updated_at,'schedule_type',p_schedule_type,'weekday_mask',p_weekday_mask,
  'weekly_target',p_weekly_target,'target_milliunits',p_target_milliunits);
 select * into v_operation from private.habit_edit_operations where user_id=v_user and operation_id=p_operation_id;
 if found then
   if v_operation.request <> v_request then raise exception 'operation_reused' using errcode = 'HT005'; end if;
   return v_operation.result;
 end if;
 select * into v_habit from public.habits where id=p_habit_id and user_id=v_user for update;
 if not found then raise exception 'not_found' using errcode = 'HT004'; end if;
 if v_habit.updated_at <> p_expected_updated_at then raise exception 'revision_conflict' using errcode = 'HT008'; end if;
 select * into v_definition from public.habit_definitions where habit_id=p_habit_id and user_id=v_user order by effective_from limit 1;
 -- Clock is read after locking. Zone, week start, measurement and unit remain fixed.
 v_today := (clock_timestamp() at time zone v_definition.time_zone)::date;
 v_effective := v_today - ((extract(isodow from v_today)::int-v_definition.week_start_day+7)%7) + 7;
 if not coalesce(case p_schedule_type
   when 'daily' then p_weekday_mask is null and p_weekly_target is null
   when 'weekdays' then p_weekday_mask between 1 and 127 and p_weekly_target is null
   when 'weekly' then p_weekly_target between 1 and 7 and p_weekday_mask is null end,false)
   or not coalesce(case v_definition.measurement_mode
   when 'binary' then p_target_milliunits is null
   when 'quantity' then p_target_milliunits between 1 and 999999999999 end,false) then
   raise exception 'invalid_input' using errcode = 'HT003';
 end if;
 insert into public.habit_definitions(habit_id,user_id,effective_from,measurement_mode,schedule_type,
  weekday_mask,weekly_target,target_milliunits,unit_label,time_zone,week_start_day)
 values(p_habit_id,v_user,v_effective,v_definition.measurement_mode,p_schedule_type,
  p_weekday_mask,p_weekly_target,p_target_milliunits,v_definition.unit_label,v_definition.time_zone,v_definition.week_start_day)
 on conflict(habit_id,effective_from) do update
  set schedule_type=excluded.schedule_type,weekday_mask=excluded.weekday_mask,weekly_target=excluded.weekly_target,
   target_milliunits=excluded.target_milliunits,updated_at=clock_timestamp();
 update public.habits set name=btrim(p_name),updated_at=greatest(clock_timestamp(),v_habit.updated_at+interval '1 microsecond')
  where id=p_habit_id returning * into v_habit;
 v_result := jsonb_build_object('operation_id',p_operation_id,'habit_id',p_habit_id,
  'updated_at',v_habit.updated_at,'effective_from',v_effective);
 insert into private.habit_edit_operations(user_id,operation_id,habit_id,request,result)
  values(v_user,p_operation_id,p_habit_id,v_request,v_result);
 return v_result;
end;
$$;
revoke all on function public.edit_habit(uuid,uuid,text,timestamptz,text,smallint,smallint,bigint) from public,anon,authenticated,service_role;
grant execute on function public.edit_habit(uuid,uuid,text,timestamptz,text,smallint,smallint,bigint) to authenticated;
create or replace function public.record_habit_day(p_operation_id uuid, p_habit_id uuid, p_occurrence_date date,
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
  select * into v_definition from public.habit_definitions where habit_id = p_habit_id and user_id = v_user order by effective_from limit 1;
  v_day := (clock_timestamp() at time zone v_definition.time_zone)::date;
  if p_occurrence_date is null or p_kind is null or p_kind not in ('set_binary', 'add_amount', 'set_total') then
    raise exception 'invalid_input' using errcode = 'HT003';
  end if;
  if not private.habit_date_writable(p_occurrence_date, v_day) then
    raise exception 'outside_window' using errcode = 'HT006';
  end if;
  select * into v_definition from public.habit_definitions where habit_id = p_habit_id and user_id = v_user
    and effective_from <= p_occurrence_date order by effective_from desc limit 1;
  if not found then raise exception 'ineligible_date' using errcode = 'HT007'; end if;
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
comment on table public.habit_definitions is 'Historical versions; edits become effective next account week. Only future pending versions may be replaced by RPC.';
