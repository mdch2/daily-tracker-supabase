import { spawn, spawnSync } from "node:child_process";
import { readFileSync, readdirSync } from "node:fs";
import { randomUUID } from "node:crypto";

// Independent disposable database in the existing LOCAL PostgreSQL container.
// It has the installed auth.uid implementation and a minimal synthetic Auth table;
// it never resets, clones user data from, or deploys to the application database.
const container = "supabase_db_daily-tracker";
const database = `habit_test_${randomUUID().replaceAll("-", "")}`;
function sql(statement, db = database) {
  const result = spawnSync(
    "docker",
    [
      "exec",
      "-i",
      container,
      "psql",
      "-U",
      "postgres",
      "-d",
      db,
      "-X",
      "-A",
      "-t",
      "-v",
      "ON_ERROR_STOP=1",
    ],
    {
      input:
        db === "postgres"
          ? statement
          : "set search_path = public, extensions;" + statement,
      encoding: "utf8",
    },
  );
  if (result.error || result.status !== 0)
    throw new Error(result.stderr || "PostgreSQL check failed");
  return result.stdout;
}
function connection(statement) {
  const child = spawn("docker", [
    "exec",
    "-i",
    container,
    "psql",
    "-U",
    "postgres",
    "-d",
    database,
    "-X",
    "-A",
    "-t",
    "-v",
    "ON_ERROR_STOP=1",
  ]);
  let output = "";
  let error = "";
  let ready;
  const holding = new Promise((resolve) => {
    ready = resolve;
  });
  child.stdout.on("data", (chunk) => {
    output += chunk;
    if (output.includes("HOLDING")) ready();
  });
  child.stderr.on("data", (chunk) => {
    error += chunk;
  });
  const done = new Promise((resolve, reject) => {
    child.on("error", reject);
    child.on("close", (code) => {
      ready();
      resolve({ code, output, error });
    });
  });
  child.stdin.end(statement);
  return { done, holding };
}
const snapshotQuery =
  "select md5(jsonb_build_object('habit',to_jsonb(h),'definition',to_jsonb(d),'record',to_jsonb(r))::text) from public.habits h join public.habit_definitions d on d.habit_id=h.id join public.habit_day_records r on r.habit_id=h.id where h.id='22000000-0000-4000-8000-000000000006';";
let preservedHabitSnapshot;

const user = "22000000-0000-4000-8000-000000000001";
const habit = "22000000-0000-4000-8000-000000000002";
const actor = `set local role authenticated; select set_config('request.jwt.claims','{"sub":"${user}","role":"authenticated"}',true);`;
const command = (
  operation,
  kind = "add_amount",
  amount = 250000,
  revision = "null",
) =>
  `select public.record_habit_day('${operation}','${habit}',(clock_timestamp() at time zone 'UTC')::date,'${kind}',null,${amount},${revision});`;
async function overlap(first, second, expectedSecond = 0) {
  const a = connection(
    `begin; ${actor} ${first} select 'HOLDING'; select pg_sleep(1); commit;`,
  );
  await a.holding;
  const b = connection(`begin; ${actor} ${second} commit;`);
  const [left, right] = await Promise.all([a.done, b.done]);
  if (left.code !== 0 || right.code !== expectedSecond)
    throw new Error(left.error + right.error);
  if (expectedSecond !== 0 && !right.error.includes("revision_conflict"))
    throw new Error("Expected revision conflict");
}
try {
  const authUid = sql(
    "select pg_get_functiondef('auth.uid()'::regprocedure);",
    "postgres",
  );
  sql(`create database ${database};`, "postgres");
  sql(`create schema auth; create schema extensions; create extension pgtap with schema extensions; grant usage on schema extensions to anon, authenticated;
    create table auth.users (id uuid primary key, email text, raw_user_meta_data jsonb);
    ${authUid};
    grant usage on schema auth to anon, authenticated;
    grant execute on function auth.uid() to anon, authenticated;`);
  const migrations = readdirSync("supabase/migrations")
    .filter((name) => name.endsWith(".sql"))
    .sort();
  for (const name of migrations) {
    if (name === "20261021000100_habits.sql") {
      sql(`insert into auth.users(id,email) values ('${user}','migration-survival@example.test');
        update public.profiles set display_name='Preserved profile' where id='${user}';`);
    }
    if (name === "20261023000100_habit_names.sql") {
      sql(`insert into auth.users(id,email) values ('22000000-0000-4000-8000-000000000005','habit-migration@example.test');
        begin; set local role authenticated;
        select set_config('request.jwt.claims','{"sub":"22000000-0000-4000-8000-000000000005","role":"authenticated"}',true);
        select public.initialize_habit_calendar('UTC',1::smallint);
        select public.create_habit('22000000-0000-4000-8000-000000000006','Preserved habit','quantity','daily',null,null,20000,'pages');
        select public.record_habit_day('22000000-0000-4000-8000-000000000007','22000000-0000-4000-8000-000000000006',(clock_timestamp() at time zone 'UTC')::date,'add_amount',null,10000);
        commit;`);
      preservedHabitSnapshot = sql(snapshotQuery);
    }
    sql(readFileSync(`supabase/migrations/${name}`, "utf8"));
  }
  sql(`do $$ begin if not exists (select 1 from public.profiles where id='${user}'
    and display_name='Preserved profile' and time_zone is null and week_start_day is null)
    then raise exception 'Incremental migration lost data'; end if; end $$;`);
  process.stdout.write(
    "Full application migration chain and incremental profile preservation: PASS\n",
  );
  if (!preservedHabitSnapshot || preservedHabitSnapshot !== sql(snapshotQuery))
    throw new Error(
      "Incremental edit migrations changed an existing habit, definition or record",
    );
  process.stdout.write(
    "Incremental habit, definition and record preservation: PASS\n",
  );
  for (const name of readdirSync("supabase/tests/database")
    .filter((name) => name.endsWith(".test.sql"))
    .sort()) {
    const tap = sql(readFileSync(`supabase/tests/database/${name}`, "utf8"));
    const plans = [...tap.matchAll(/^1\.\.(\d+)$/gm)];
    const passed = [...tap.matchAll(/^ok \d+/gm)].length;
    if (
      plans.length !== 1 ||
      passed !== Number(plans[0][1]) ||
      /^not ok|^# Looks like/m.test(tap)
    ) {
      throw new Error(`TAP failed: ${name}\n${tap}`);
    }
    process.stdout.write(`${name}: ${passed} checks PASS\n`);
  }
  sql(`begin; ${actor} select public.initialize_habit_calendar('UTC',1::smallint);
    select public.create_habit('${habit}','Concurrent synthetic habit','quantity','daily',null,null,20000,'ml'); commit;`);
  const a = randomUUID();
  await overlap(command(a), command(a));
  sql(`do $$ begin if not exists (select 1 from public.habit_day_records where habit_id='${habit}'
    and amount_milliunits=250000 and revision=1) then raise exception 'Duplicate applied twice'; end if; end $$;`);
  await overlap(command(randomUUID()), command(randomUUID()));
  sql(`do $$ begin if not exists (select 1 from public.habit_day_records where habit_id='${habit}'
    and amount_milliunits=750000 and revision=3) then raise exception 'Concurrent contribution lost'; end if; end $$;`);
  await overlap(
    command(randomUUID()),
    command(randomUUID(), "set_total", 1, 3),
    3,
  );
  sql(`do $$ begin if not exists (select 1 from public.habit_day_records where habit_id='${habit}'
    and amount_milliunits=1000000 and revision=4) then raise exception 'Stale correction overwrote contribution'; end if; end $$;`);
  process.stdout.write(
    "Two real concurrent client connections: duplicate, addition and stale correction PASS\n",
  );
  const renameCommand = (operation, name, token) =>
    `select public.rename_habit('${operation}','${habit}','${name}','${token}'::timestamptz);`;
  const firstToken = sql(
    `select updated_at::text from public.habits where id='${habit}';`,
  )
    .trim()
    .split(/\r?\n/)
    .at(-1);
  const renameOperation = randomUUID();
  await overlap(
    renameCommand(renameOperation, "Renamed", firstToken),
    renameCommand(renameOperation, "Renamed", firstToken),
  );
  const renameToken = sql(
    `select updated_at::text from public.habits where id='${habit}';`,
  )
    .trim()
    .split(/\r?\n/)
    .at(-1);
  await overlap(
    renameCommand(randomUUID(), "Latest name", renameToken),
    renameCommand(randomUUID(), "Stale name", renameToken),
    3,
  );
  const editCommand = (operation, token, target) =>
    `select public.edit_habit('${operation}','${habit}','Planned concurrent goal','${token}'::timestamptz,'weekly',null,3::smallint,${target});`;
  const editToken = sql(
    `select updated_at::text from public.habits where id='${habit}';`,
  )
    .trim()
    .split(/\r?\n/)
    .at(-1);
  const editOperation = randomUUID();
  await overlap(
    editCommand(editOperation, editToken, 30000),
    editCommand(editOperation, editToken, 30000),
  );
  const latestToken = sql(
    `select updated_at::text from public.habits where id='${habit}';`,
  )
    .trim()
    .split(/\r?\n/)
    .at(-1);
  await overlap(
    editCommand(randomUUID(), latestToken, 40000),
    editCommand(randomUUID(), latestToken, 50000),
    3,
  );
  sql(`do $$ begin if (select count(*) from public.habit_definitions where habit_id='${habit}') <> 2
    or (select target_milliunits from public.habit_definitions where habit_id='${habit}' order by effective_from desc limit 1) <> 40000
    then raise exception 'Concurrent pending configuration lost or duplicated'; end if; end $$;`);
  process.stdout.write(
    "Concurrent metadata/configuration retries and stale edits: PASS\n",
  );

  const routine = randomUUID();
  const ownStep = randomUUID();
  const routineSteps = JSON.stringify([
    {
      id: ownStep,
      kind: "own",
      title: "Synthetic routine step",
      required: true,
    },
  ]);
  const createRoutine = `select public.create_routine('${routine}','Concurrent routine','daily','${routineSteps}'::jsonb);`;
  await overlap(createRoutine, createRoutine);
  const ownCommand = (operation, revision, completed = true) =>
    `select public.record_routine_step('${operation}','${routine}','${ownStep}',(clock_timestamp() at time zone 'UTC')::date,${completed},${revision});`;
  const ownOperation = randomUUID();
  await overlap(ownCommand(ownOperation, 0), ownCommand(ownOperation, 0));
  await overlap(
    ownCommand(randomUUID(), 1, false),
    ownCommand(randomUUID(), 1, true),
    3,
  );
  sql(`do $$ begin if not exists(select 1 from public.routine_step_day_records where routine_id='${routine}' and revision=2 and completed=false)
    then raise exception 'Routine lost a concurrent update or applied a replay twice'; end if; end $$;`);
  const routineToken = () =>
    sql(`select updated_at::text from public.routines where id='${routine}';`)
      .trim()
      .split(/\r?\n/)
      .at(-1);
  const routineEdit = (operation, token, name) =>
    `select public.edit_routine('${operation}','${routine}','${name}','${token}'::timestamptz,'daily','${routineSteps}'::jsonb);`;
  const initialRoutineToken = routineToken();
  const routineEditOperation = randomUUID();
  await overlap(
    routineEdit(routineEditOperation, initialRoutineToken, "Renamed routine"),
    routineEdit(routineEditOperation, initialRoutineToken, "Renamed routine"),
  );
  const latestRoutineToken = routineToken();
  await overlap(
    routineEdit(randomUUID(), latestRoutineToken, "Latest routine"),
    routineEdit(randomUUID(), latestRoutineToken, "Stale routine"),
    3,
  );
  await overlap(
    routineEdit(randomUUID(), routineToken(), "Edited while recording"),
    ownCommand(randomUUID(), 2),
  );
  const archiveOperation = randomUUID();
  const archiveToken = routineToken();
  const archiveRoutine = `select public.archive_routine('${archiveOperation}','${routine}','${archiveToken}'::timestamptz);`;
  await overlap(archiveRoutine, archiveRoutine);
  sql(`begin; ${actor} ${ownCommand(ownOperation, 0)} commit;`);
  sql(`do $$ begin if (select revision from public.routine_step_day_records where routine_id='${routine}')<>3
    or (select count(*) from public.routine_definitions where routine_id='${routine}')<>2
    then raise exception 'Routine archive/replay changed history'; end if; end $$;`);
  process.stdout.write(
    "Routine concurrency: creation, replay, stale record/configuration, edit/record and archive PASS\n",
  );
} finally {
  // The identifier is generated here, never accepted from arguments/environment.
  if (!/^habit_test_[a-f0-9]{32}$/.test(database))
    throw new Error("Unsafe disposable database identifier");
  sql(`drop database if exists ${database} with (force);`, "postgres");
}
