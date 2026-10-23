import { spawn, spawnSync } from 'node:child_process';
import { readFileSync, readdirSync } from 'node:fs';
import { randomUUID } from 'node:crypto';

// Independent disposable database in the existing LOCAL PostgreSQL container.
// It has the installed auth.uid implementation and a minimal synthetic Auth table;
// it never resets, clones user data from, or deploys to the application database.
const container = 'supabase_db_daily-tracker';
const database = `habit_test_${randomUUID().replaceAll('-', '')}`;
function sql(statement, db = database) {
  const result = spawnSync('docker', ['exec', '-i', container, 'psql', '-U', 'postgres', '-d', db,
    '-X', '-A', '-t', '-v', 'ON_ERROR_STOP=1'], { input: db === 'postgres' ? statement : 'set search_path = public, extensions;' + statement, encoding: 'utf8' });
  if (result.error || result.status !== 0) throw new Error(result.stderr || 'PostgreSQL check failed');
  return result.stdout;
}
function connection(statement) {
  const child = spawn('docker', ['exec', '-i', container, 'psql', '-U', 'postgres', '-d', database,
    '-X', '-A', '-t', '-v', 'ON_ERROR_STOP=1']);
  let output = ''; let error = ''; let ready;
  const holding = new Promise(resolve => { ready = resolve; });
  child.stdout.on('data', chunk => { output += chunk; if (output.includes('HOLDING')) ready(); });
  child.stderr.on('data', chunk => { error += chunk; });
  const done = new Promise((resolve, reject) => {
    child.on('error', reject);
    child.on('close', code => { ready(); resolve({ code, output, error }); });
  });
  child.stdin.end(statement);
  return { done, holding };
}
const user = '22000000-0000-4000-8000-000000000001';
const habit = '22000000-0000-4000-8000-000000000002';
const actor = `set local role authenticated; select set_config('request.jwt.claims','{"sub":"${user}","role":"authenticated"}',true);`;
const command = (operation, kind = 'add_amount', amount = 250000, revision = 'null') =>
  `select public.record_habit_day('${operation}','${habit}',(clock_timestamp() at time zone 'UTC')::date,'${kind}',null,${amount},${revision});`;
async function overlap(first, second, expectedSecond = 0) {
  const a = connection(`begin; ${actor} ${first} select 'HOLDING'; select pg_sleep(1); commit;`);
  await a.holding;
  const b = connection(`begin; ${actor} ${second} commit;`);
  const [left, right] = await Promise.all([a.done, b.done]);
  if (left.code !== 0 || right.code !== expectedSecond) throw new Error(left.error + right.error);
  if (expectedSecond !== 0 && !right.error.includes('revision_conflict')) throw new Error('Expected revision conflict');
}
try {
  const authUid = sql("select pg_get_functiondef('auth.uid()'::regprocedure);", 'postgres');
  sql(`create database ${database};`, 'postgres');
  sql(`create schema auth; create schema extensions; create extension pgtap with schema extensions; grant usage on schema extensions to anon, authenticated;
    create table auth.users (id uuid primary key, email text, raw_user_meta_data jsonb);
    ${authUid};
    grant usage on schema auth to anon, authenticated;
    grant execute on function auth.uid() to anon, authenticated;`);
  const migrations = readdirSync('supabase/migrations').filter(name => name.endsWith('.sql')).sort();
  for (const name of migrations) {
    if (name === '20261021000100_habits.sql') {
      sql(`insert into auth.users(id,email) values ('${user}','migration-survival@example.test');
        update public.profiles set display_name='Preserved profile' where id='${user}';`);
    }
    sql(readFileSync(`supabase/migrations/${name}`, 'utf8'));
  }
  sql(`do $$ begin if not exists (select 1 from public.profiles where id='${user}'
    and display_name='Preserved profile' and time_zone is null and week_start_day is null)
    then raise exception 'Incremental migration lost data'; end if; end $$;`);
  process.stdout.write('Full application migration chain and incremental profile preservation: PASS\n');
  for (const name of readdirSync('supabase/tests/database').filter(name => name.endsWith('.test.sql')).sort()) {
    const tap = sql(readFileSync(`supabase/tests/database/${name}`, 'utf8'));
    const plans = [...tap.matchAll(/^1\.\.(\d+)$/gm)];
    const passed = [...tap.matchAll(/^ok \d+/gm)].length;
    if (plans.length !== 1 || passed !== Number(plans[0][1]) || /^not ok|^# Looks like/m.test(tap)) {
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
  await overlap(command(randomUUID()), command(randomUUID(),'set_total',1,3), 3);
  sql(`do $$ begin if not exists (select 1 from public.habit_day_records where habit_id='${habit}'
    and amount_milliunits=1000000 and revision=4) then raise exception 'Stale correction overwrote contribution'; end if; end $$;`);
  process.stdout.write('Two real concurrent client connections: duplicate, addition and stale correction PASS\n');
} finally {
  // The identifier is generated here, never accepted from arguments/environment.
  if (!/^habit_test_[a-f0-9]{32}$/.test(database)) throw new Error('Unsafe disposable database identifier');
  sql(`drop database if exists ${database} with (force);`, 'postgres');
}
