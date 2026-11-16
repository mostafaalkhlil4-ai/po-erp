-- DB-level tests for migration 0001. Run via scripts/test-db.sh
-- Each test raises an exception on failure; psql runs with ON_ERROR_STOP.
create schema tests;
grant usage on schema tests to anon, authenticated;
alter default privileges in schema tests grant execute on functions to anon, authenticated;

create function tests.login(uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', uid::text, true);
  execute 'set local role authenticated';
end $$;

create function tests.anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', '', true);
  execute 'set local role anon';
end $$;

create function tests.logout() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', '', true);
end $$;

-- Runs sql as the current role and asserts it fails with the given SQLSTATE
-- (default: any error). Uses a savepoint so the outer test continues.
create function tests.expect_error(p_name text, p_sql text, p_state text default null)
returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if p_state is null or sqlstate = p_state then
      raise notice 'PASS: % (%)', p_name, sqlstate;
      return;
    end if;
    raise exception 'FAIL: % - wrong error % (%)', p_name, sqlstate, sqlerrm;
  end;
  raise exception 'FAIL: % - statement succeeded but must be denied', p_name;
end $$;

create function tests.eq(p_name text, p_actual anyelement, p_expected anyelement)
returns void language plpgsql as $$
begin
  if p_actual is not distinct from p_expected then
    raise notice 'PASS: %', p_name;
  else
    raise exception 'FAIL: % - expected %, got %', p_name, p_expected, p_actual;
  end if;
end $$;

-- Fixture users (synthetic data only)
do $$
declare
  u record;
begin
  for u in select * from (values
    ('00000000-0000-0000-0000-0000000000a1'::uuid, 'admin@test.local'),
    ('00000000-0000-0000-0000-0000000000a2'::uuid, 'mgmt@test.local'),
    ('00000000-0000-0000-0000-0000000000a3'::uuid, 'tech@test.local'),
    ('00000000-0000-0000-0000-0000000000a4'::uuid, 'doctor@test.local'),
    ('00000000-0000-0000-0000-0000000000a5'::uuid, 'patient1@test.local'),
    ('00000000-0000-0000-0000-0000000000a6'::uuid, 'patient2@test.local')
  ) as t(id, email) loop
    insert into auth.users (id, email) values (u.id, u.email);
  end loop;

  -- Trusted server context (auth.uid() is null): activate and assign roles.
  update public.profiles set role = 'admin',      is_active = true where email = 'admin@test.local';
  update public.profiles set role = 'management', is_active = true where email = 'mgmt@test.local';
  update public.profiles set role = 'technician', is_active = true where email = 'tech@test.local';
  update public.profiles set role = 'doctor',     is_active = true where email = 'doctor@test.local';
  update public.profiles set role = 'patient',    is_active = true where email in ('patient1@test.local','patient2@test.local');
end $$;

-- ---------------------------------------------------------------------
-- T1 signup defaults + no escalation via metadata
-- ---------------------------------------------------------------------
do $$
declare r public.profiles;
begin
  insert into auth.users (id, email, raw_user_meta_data)
  values ('00000000-0000-0000-0000-0000000000b1', 'evil@test.local',
          '{"role":"admin","is_active":true,"full_name":"Evil"}');
  select * into r from public.profiles where email = 'evil@test.local';
  perform tests.eq('T1a new signup role is patient (metadata ignored)', r.role::text, 'patient');
  perform tests.eq('T1b new signup is inactive', r.is_active, false);
end $$;

-- T2 inactive user has no permissions at all
do $$
begin
  perform tests.login('00000000-0000-0000-0000-0000000000b1');
  perform tests.eq('T2a inactive: no portal.self', public.has_permission('portal.self'), false);
  perform tests.eq('T2b inactive: no current role', public.current_app_role() is null, true);
  perform tests.logout();
end $$;

-- T3 anonymous access denied
do $$
begin
  perform tests.anon();
  perform tests.expect_error('T3a anon cannot read profiles', 'select * from public.profiles', '42501');
  perform tests.expect_error('T3b anon cannot read audit_logs', 'select * from public.audit_logs', '42501');
  perform tests.expect_error('T3c anon cannot read role_permissions', 'select * from public.role_permissions', '42501');
  perform tests.logout();
end $$;

-- T4 patient: sees only self; cannot escalate; can edit harmless fields
do $$
begin
  perform tests.login('00000000-0000-0000-0000-0000000000a5');
  perform tests.eq('T4a patient sees only own profile', (select count(*) from public.profiles)::int, 1);
  perform tests.expect_error('T4b patient cannot set own role',
    $q$update public.profiles set role = 'admin' where id = '00000000-0000-0000-0000-0000000000a5'$q$);
  perform tests.expect_error('T4c patient cannot reactivate/modify status',
    $q$update public.profiles set is_active = false where id = '00000000-0000-0000-0000-0000000000a5'$q$);
  update public.profiles set full_name = 'Patient One', locale = 'en'
   where id = '00000000-0000-0000-0000-0000000000a5';
  perform tests.eq('T4d patient can edit own name', (select full_name from public.profiles), 'Patient One');
  update public.profiles set full_name = 'Hacked'
   where id = '00000000-0000-0000-0000-0000000000a6';
  perform tests.logout();
  perform tests.eq('T4e patient cannot edit others (0 rows changed)',
    (select full_name from public.profiles where email = 'patient2@test.local'), '');
  perform tests.login('00000000-0000-0000-0000-0000000000a5');
  perform tests.eq('T4f patient sees 0 audit rows (RLS filters)', (select count(*) from public.audit_logs)::int, 0);
  perform tests.expect_error('T4g patient cannot delete profiles', 'delete from public.profiles', '42501');
  perform tests.expect_error('T4h patient cannot write role_permissions',
    $q$insert into public.role_permissions values ('patient','finance.manage')$q$);
  perform tests.logout();
end $$;

-- T5 management: operational only, no role admin / audit / admin profiles
do $$
begin
  perform tests.login('00000000-0000-0000-0000-0000000000a2');
  perform tests.eq('T5a management cannot see admin profile',
    (select count(*) from public.profiles where role = 'admin')::int, 0);
  perform tests.eq('T5b management sees patient/doctor/technician profiles + self',
    (select count(*) from public.profiles)::int, 6);  -- tech, doctor, 2 patients, evil(T1, patient), self
  update public.profiles set role = 'admin' where id = '00000000-0000-0000-0000-0000000000a5';
  perform tests.eq('T5c management cannot change others'' roles (RLS: 0 rows)',
    (select role::text from public.profiles where id = '00000000-0000-0000-0000-0000000000a5'), 'patient');
  perform tests.expect_error('T5d management cannot self-promote',
    $q$update public.profiles set role = 'admin' where id = '00000000-0000-0000-0000-0000000000a2'$q$);
  perform tests.eq('T5e management sees 0 audit rows', (select count(*) from public.audit_logs)::int, 0);
  perform tests.expect_error('T5f management cannot edit role_permissions',
    $q$insert into public.role_permissions values ('management','users.manage')$q$);
  perform tests.eq('T5g management has finance.manage', public.has_permission('finance.manage'), true);
  perform tests.eq('T5h management lacks users.manage', public.has_permission('users.manage'), false);
  perform tests.logout();
end $$;

-- T6 admin: can manage roles; changes are audited
do $$
declare before_n int; after_n int;
begin
  perform tests.login('00000000-0000-0000-0000-0000000000a1');
  perform tests.eq('T6a admin sees all profiles', (select count(*) from public.profiles)::int, 7);
  select count(*) into before_n from public.audit_logs;
  update public.profiles set is_active = true, role = 'technician'
   where email = 'evil@test.local';
  select count(*) into after_n from public.audit_logs;
  perform tests.eq('T6b role change wrote an audit row', after_n - before_n, 1);
  perform tests.eq('T6c audit row records actor',
    (select actor_id from public.audit_logs order by id desc limit 1),
    '00000000-0000-0000-0000-0000000000a1'::uuid);
  perform tests.eq('T6d audit row has old/new role',
    (select (old_data->>'role') || '>' || (new_data->>'role') from public.audit_logs order by id desc limit 1),
    'patient>technician');
  perform tests.logout();
end $$;

-- T7 audit log is append-only for everyone, including admin and superuser
do $$
begin
  perform tests.login('00000000-0000-0000-0000-0000000000a1');
  perform tests.expect_error('T7a admin cannot update audit', 'update public.audit_logs set action = ''x''', '42501');
  perform tests.expect_error('T7b admin cannot delete audit', 'delete from public.audit_logs', '42501');
  perform tests.expect_error('T7c admin cannot insert audit directly',
    $q$insert into public.audit_logs (action, entity_type) values ('FORGED','x')$q$, '42501');
  perform tests.expect_error('T7d admin cannot call write_audit via API',
    $q$select public.write_audit('FORGED','x','1')$q$, '42501');
  perform tests.logout();
  perform tests.expect_error('T7e superuser update blocked by trigger', 'update public.audit_logs set action = ''x''', 'P0001');
  perform tests.expect_error('T7f superuser delete blocked by trigger', 'delete from public.audit_logs', 'P0001');
  perform tests.expect_error('T7g truncate blocked by trigger', 'truncate public.audit_logs', 'P0001');
end $$;

-- T8 last active admin cannot be removed
do $$
begin
  perform tests.login('00000000-0000-0000-0000-0000000000a1');
  perform tests.expect_error('T8a last admin cannot be demoted',
    $q$update public.profiles set role = 'management' where id = '00000000-0000-0000-0000-0000000000a1'$q$, '23514');
  perform tests.expect_error('T8b last admin cannot be deactivated',
    $q$update public.profiles set is_active = false where id = '00000000-0000-0000-0000-0000000000a1'$q$, '23514');
  perform tests.logout();
end $$;

-- T9 permission matrix vs RBAC_MATRIX.md
do $$
declare
  c text;
begin
  perform tests.eq('T9a admin holds every permission',
    (select count(*) from public.role_permissions where role = 'admin')::int,
    (select count(*) from public.permissions)::int);
  foreach c in array array['users.manage','roles.manage','settings.manage','audit.read'] loop
    perform tests.eq('T9b management lacks ' || c,
      exists (select 1 from public.role_permissions where role = 'management' and permission_code = c), false);
  end loop;
  foreach c in array array['finance.manage','invoices.read','quotations.manage','inventory.manage','procurement.manage'] loop
    perform tests.eq('T9c technician lacks ' || c,
      exists (select 1 from public.role_permissions where role = 'technician' and permission_code = c), false);
    perform tests.eq('T9d doctor lacks ' || c,
      exists (select 1 from public.role_permissions where role = 'doctor' and permission_code = c), false);
    perform tests.eq('T9e patient lacks ' || c,
      exists (select 1 from public.role_permissions where role = 'patient' and permission_code = c), false);
  end loop;
  perform tests.eq('T9f patient lacks patients.read_all',
    exists (select 1 from public.role_permissions where role = 'patient' and permission_code = 'patients.read_all'), false);
  perform tests.eq('T9g every role can read catalog',
    (select count(*) from public.role_permissions where permission_code = 'catalog.read')::int, 5);
end $$;

-- T10 profile delete is impossible for clients; auth.users deletion restricted
do $$
begin
  perform tests.login('00000000-0000-0000-0000-0000000000a1');
  perform tests.expect_error('T10a admin cannot delete profiles', 'delete from public.profiles', '42501');
  perform tests.logout();
  perform tests.expect_error('T10b auth user with profile cannot be deleted (history preserved)',
    $q$delete from auth.users where email = 'patient1@test.local'$q$, '23503');
end $$;

select 'ALL DB TESTS PASSED' as result;
