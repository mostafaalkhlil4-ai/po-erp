-- Phase 5: production stages and quality control (D-026). Synthetic data only.
create table tests.p5 (k text primary key, v uuid);
grant select, insert on tests.p5 to authenticated;

do $$
declare
  mgmt uuid := '00000000-0000-0000-0000-0000000000a2';
  tech uuid := '00000000-0000-0000-0000-0000000000a3';
  doc  uuid := '00000000-0000-0000-0000-0000000000a4';
  pat1 uuid := '00000000-0000-0000-0000-0000000000a5';
  pat2 uuid := '00000000-0000-0000-0000-0000000000a6';
  p1 uuid; cx uuid; s1 uuid; s2 uuid; st record;
begin
  select id into p1 from public.patients where user_id = pat1;
  perform tests.login(mgmt);
  insert into public.cases (patient_id, case_type) values (p1, 'prosthetic') returning id into cx;
  insert into public.case_assignments (case_id, technician_id) values (cx, tech);
  perform tests.expect_error('T80a stages cannot be planned while case is in assessment',
    format('insert into public.production_stages (case_id, name) values (%L, %L)', cx, 'Casting'), '23514');
  perform tests.logout();
  update public.cases set status = 'approved' where id = cx;   -- trusted setup (approval path tested in 07)
  insert into tests.p5 values ('case', cx);

  perform tests.login(mgmt);
  insert into public.production_stages (case_id, name, position) values (cx, 'Casting', 1) returning id into s1;
  perform tests.eq('T80b stage created pending with creator set', (select status || '/' || (created_by = mgmt)::text from public.production_stages where id = s1), 'pending/true');
  perform tests.logout();
  perform tests.login(tech);
  insert into public.production_stages (case_id, name, position, status, completed_at) values (cx, 'Fabrication', 2, 'completed', now()) returning id into s2;
  perform tests.eq('T80c client-sent status/completion ignored (forced pending)', (select status || '/' || (completed_at is null)::text from public.production_stages where id = s2), 'pending/true');
  perform tests.expect_error('T80d stage work refused before production',
    format('select public.set_stage_status(%L, %L)', s1, 'in_progress'), '23514');
  perform tests.logout();
  perform tests.login(doc);
  perform tests.expect_error('T80e doctor cannot create stages',
    format('insert into public.production_stages (case_id, name) values (%L, %L)', cx, 'X'), '42501');
  perform tests.logout();
  perform tests.login(pat1);
  perform tests.expect_error('T80f patient cannot create stages',
    format('insert into public.production_stages (case_id, name) values (%L, %L)', cx, 'X'), '42501');
  perform tests.eq('T80g patient sees no stages', (select count(*) from public.production_stages)::int, 0);
  perform tests.logout();

  update public.cases set status = 'production' where id = cx;   -- trusted setup
  insert into tests.p5 values ('s1', s1), ('s2', s2);

  perform tests.login(doc);
  perform tests.expect_error('T80h doctor cannot change stage status',
    format('select public.set_stage_status(%L, %L)', s1, 'in_progress'), '42501');
  perform tests.logout();
  perform tests.anon();
  perform tests.expect_error('T80i anon cannot change stage status',
    format('select public.set_stage_status(%L, %L)', s1, 'in_progress'), '42501');
  perform tests.logout();

  perform tests.login(tech);
  perform tests.expect_error('T80j cannot skip pending -> completed',
    format('select public.set_stage_status(%L, %L)', s1, 'completed'), '23514');
  perform tests.expect_error('T80k direct stage update denied',
    format('update public.production_stages set status = %L where id = %L', 'completed', s1), '42501');
  perform tests.expect_error('T80l stage delete denied', 'delete from public.production_stages', '42501');
  perform public.set_stage_status(s1, 'in_progress', 'started');
  perform tests.eq('T80m start records responsible user and time',
    (select (responsible_id = tech)::text || '/' || (started_at is not null)::text from public.production_stages where id = s1), 'true/true');
  perform tests.expect_error('T80n cannot enter quality control with unfinished stages',
    format('select public.advance_case(%L, %L)', cx, 'quality_control'), '23514');
  perform public.set_stage_status(s1, 'completed', 'done');
  perform tests.expect_error('T80o QC still blocked while another stage is pending',
    format('select public.advance_case(%L, %L)', cx, 'quality_control'), '23514');
  perform public.set_stage_status(s2, 'in_progress');
  perform public.set_stage_status(s2, 'completed');
  perform tests.expect_error('T80p completed stage cannot be restarted',
    format('select public.set_stage_status(%L, %L)', s2, 'in_progress'), '23514');
  perform tests.eq('T80q completed stage keeps notes', (select notes from public.production_stages where id = s1), 'done');
  perform public.advance_case(cx, 'quality_control');
  perform tests.eq('T80r case reached quality_control', (select status from public.cases where id = cx), 'quality_control');
  perform tests.logout();
  perform tests.eq('T80s stage changes audited', (select count(*) from public.audit_logs where entity_type = 'production_stages')::int >= 6, true);
end $$;

do $$
declare
  tech uuid := '00000000-0000-0000-0000-0000000000a3';
  doc  uuid := '00000000-0000-0000-0000-0000000000a4';
  pat1 uuid := '00000000-0000-0000-0000-0000000000a5';
  cx uuid; c_other uuid;
begin
  select v into cx from tests.p5 where k = 'case';
  select id into c_other from public.cases where status = 'assessment' limit 1;
  perform tests.login(tech);
  perform tests.expect_error('T81a fail needs notes',
    format('insert into public.quality_checks (case_id, result) values (%L, %L)', cx, 'fail'), '23514');
  insert into public.quality_checks (case_id, result, notes) values (cx, 'fail', 'alignment off');
  perform tests.eq('T81b checked_by set server-side', (select (checked_by = tech)::text from public.quality_checks order by id desc limit 1), 'true');
  perform tests.expect_error('T81c failed QC blocks fitting',
    format('select public.advance_case(%L, %L)', cx, 'fitting'), '23514');
  perform tests.expect_error('T81d QC refused for a case not in quality_control',
    format('insert into public.quality_checks (case_id, result) values (%L, %L)', c_other, 'pass'), '23514');
  perform tests.expect_error('T81e QC is append-only (update)', 'update public.quality_checks set result = ''pass''', '42501');
  perform tests.expect_error('T81f QC is append-only (delete)', 'delete from public.quality_checks', '42501');
  perform tests.logout();
  perform tests.login(doc);
  perform tests.expect_error('T81g doctor cannot record QC',
    format('insert into public.quality_checks (case_id, result) values (%L, %L)', cx, 'pass'), '42501');
  perform tests.logout();
  perform tests.login(pat1);
  perform tests.eq('T81h patient sees no QC', (select count(*) from public.quality_checks)::int, 0);
  perform tests.logout();
  perform tests.expect_error('T81i superuser update blocked by trigger', 'update public.quality_checks set result = ''pass''', 'P0001');
  perform tests.login(tech);
  insert into public.quality_checks (case_id, result) values (cx, 'pass');
  perform public.advance_case(cx, 'production', 'rework');    -- technicians may send back to production
  perform tests.logout();
end $$;

-- separate transaction: a pass recorded before re-entering QC must not count
do $$
declare
  tech uuid := '00000000-0000-0000-0000-0000000000a3';
  cx uuid;
begin
  select v into cx from tests.p5 where k = 'case';
  perform tests.login(tech);
  perform public.advance_case(cx, 'quality_control');
  perform tests.expect_error('T82a stale pass from the earlier QC round does not allow fitting',
    format('select public.advance_case(%L, %L)', cx, 'fitting'), '23514');
  perform tests.logout();
end $$;

do $$
declare
  tech uuid := '00000000-0000-0000-0000-0000000000a3';
  cx uuid;
begin
  select v into cx from tests.p5 where k = 'case';
  perform tests.login(tech);
  insert into public.quality_checks (case_id, result) values (cx, 'pass');
  perform public.advance_case(cx, 'fitting');
  perform tests.eq('T82b fresh passing QC allows fitting', (select status from public.cases where id = cx), 'fitting');
  perform tests.eq('T82c technician reads stages and QC of assigned case',
    (select count(*) from public.production_stages)::int || '/' || (select count(*) from public.quality_checks)::int, '2/3');
  perform tests.logout();
  perform tests.anon();
  perform tests.expect_error('T82d anon denied stages', 'select * from public.production_stages', '42501');
  perform tests.expect_error('T82e anon denied QC', 'select * from public.quality_checks', '42501');
  perform tests.logout();
end $$;
select 'PHASE 5 DB TESTS PASSED' as result;
