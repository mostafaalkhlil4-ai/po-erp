-- Fixtures from 01-04: a1 admin, a2 management, a3 technician, a4 doctor, a5/a6 patients.
do $$
declare
  admin_id uuid := '00000000-0000-0000-0000-0000000000a1';
  mgmt uuid := '00000000-0000-0000-0000-0000000000a2';
  tech uuid := '00000000-0000-0000-0000-0000000000a3';
  doc  uuid := '00000000-0000-0000-0000-0000000000a4';
  pat1 uuid := '00000000-0000-0000-0000-0000000000a5';
  pat2 uuid := '00000000-0000-0000-0000-0000000000a6';
  p1 uuid; p2 uuid; d1 uuid; c1 uuid; c2 uuid; asg uuid; n int;
begin
  select id into p1 from public.patients where user_id = pat1;
  select id into p2 from public.patients where user_id = pat2;
  select id into d1 from public.doctors where user_id = doc;
  -- trusted setup: doctor active and linked to p1 only
  update public.doctors set is_active = true where id = d1;
  update public.doctor_patient_relationships set ended_at = now() where doctor_id = d1 and ended_at is null;
  insert into public.doctor_patient_relationships (doctor_id, patient_id) values (d1, p1);

  -- ---- creation (management) ----
  perform tests.login(mgmt);
  insert into public.cases (patient_id, case_type, responsible_doctor_id) values (p1, 'prosthetic', d1) returning id into c1;
  insert into public.cases (patient_id, case_type, priority) values (p2, 'orthotic', 'high') returning id into c2;
  perform tests.eq('T50a new case starts at assessment', (select status from public.cases where id = c1), 'assessment');
  perform tests.eq('T50b created_by set server-side', (select created_by from public.cases where id = c1), mgmt);
  perform tests.eq('T50c created event written', (select count(*) from public.case_events where case_id = c1 and event_type = 'created')::int, 1);
  perform tests.expect_error('T50d cannot create a case already past assessment',
    format('insert into public.cases (patient_id, case_type, status) values (%L, %L, %L)', p1, 'prosthetic', 'production'), '42501');
  perform tests.expect_error('T50e invalid case type rejected',
    format('insert into public.cases (patient_id, case_type) values (%L, %L)', p1, 'magic'), '23514');
  perform tests.expect_error('T50f status cannot be updated directly',
    format('update public.cases set status = %L where id = %L', 'production', c1), '42501');
  perform tests.expect_error('T50g cases cannot be deleted', 'delete from public.cases', '42501');
  update public.cases set priority = 'urgent' where id = c1;
  perform tests.eq('T50h management can change priority', (select priority from public.cases where id = c1), 'urgent');
  perform tests.logout();

  -- ---- technician before assignment ----
  perform tests.login(tech);
  perform tests.eq('T51a unassigned technician sees 0 cases', (select count(*) from public.cases)::int, 0);
  perform tests.eq('T51b ...and 0 patients', (select count(*) from public.patients)::int, 0);
  perform tests.expect_error('T51c technician cannot create cases',
    format('insert into public.cases (patient_id, case_type) values (%L, %L)', p1, 'prosthetic'), '42501');
  perform tests.expect_error('T51d technician cannot self-assign',
    format('insert into public.case_assignments (case_id, technician_id) values (%L, %L)', c1, tech), '42501');
  perform tests.logout();

  -- ---- assignment ----
  perform tests.login(mgmt);
  perform tests.expect_error('T52a cannot assign a non-technician',
    format('insert into public.case_assignments (case_id, technician_id) values (%L, %L)', c1, doc), '23514');
  insert into public.case_assignments (case_id, technician_id) values (c1, tech) returning id into asg;
  perform tests.expect_error('T52b duplicate active assignment rejected',
    format('insert into public.case_assignments (case_id, technician_id) values (%L, %L)', c1, tech), '23505');
  perform tests.eq('T52c assignment event written', (select count(*) from public.case_events where case_id = c1 and event_type = 'assignment')::int, 1);
  perform tests.logout();

  perform tests.login(tech);
  perform tests.eq('T53a assigned technician sees only own case', (select count(*) from public.cases)::int, 1);
  perform tests.eq('T53b sees the right case', (select id from public.cases), c1);
  perform tests.eq('T53c sees only the patient of that case', (select count(*) from public.patients)::int, 1);
  perform tests.eq('T53d technician sees no finance/other cases (case 2 hidden)', (select count(*) from public.cases where id = c2)::int, 0);
  update public.cases set priority = 'low' where id = c1;
  perform tests.eq('T53e technician cannot change priority (RLS 0 rows)', (select priority from public.cases where id = c1), 'urgent');
  perform tests.eq('T53f technician sees clinical notes? no', (select count(*) from public.clinical_notes)::int, 0);
  perform tests.logout();

  -- ---- state machine ----
  perform tests.login(mgmt);
  perform tests.expect_error('T54a invalid jump assessment -> production rejected',
    format('select public.advance_case(%L, %L)', c1, 'production'), '23514');
  perform public.advance_case(c1, 'product_selection', 'selected');
  perform public.advance_case(c1, 'quotation');
  perform tests.expect_error('T54b quotation -> approved blocked until quotation module exists',
    format('select public.advance_case(%L, %L)', c1, 'approved'), '0A000');
  perform tests.eq('T54c status unchanged after blocked transition', (select status from public.cases where id = c1), 'quotation');
  perform tests.eq('T54d status_change events recorded', (select count(*) from public.case_events where case_id = c1 and event_type = 'status_change')::int, 2);
  perform tests.eq('T54e event stores actor and note',
    (select actor_id::text || '|' || note from public.case_events where case_id = c1 and to_status = 'product_selection'), mgmt::text || '|selected');
  perform tests.logout();

  perform tests.login(doc);
  perform tests.expect_error('T54f doctor cannot change case status',
    format('select public.advance_case(%L, %L)', c1, 'cancelled'), '42501');
  perform tests.logout();
  perform tests.anon();
  perform tests.expect_error('T54g anon cannot call advance_case',
    format('select public.advance_case(%L, %L)', c1, 'cancelled'), '42501');
  perform tests.logout();

  -- trusted: move to production (approval path arrives in Phase 4)
  update public.cases set status = 'production' where id = c1;
  perform tests.login(tech);
  perform tests.expect_error('T55a technician cannot cancel',
    format('select public.advance_case(%L, %L)', c1, 'cancelled'), '42501');
  perform tests.expect_error('T55b technician cannot skip production -> fitting',
    format('select public.advance_case(%L, %L)', c1, 'fitting'), '42501');
  -- Phase 5 gates (D-026): stages must be completed and a passing QC recorded
  perform tests.logout();
  insert into public.production_stages (case_id, name) values (c1, 'Fabrication');
  update public.production_stages set status = 'completed', started_at = now(), completed_at = now() where case_id = c1;
  perform tests.login(tech);
  perform public.advance_case(c1, 'quality_control');
  perform public.advance_case(c1, 'production', 'correction');
  perform public.advance_case(c1, 'quality_control');
  insert into public.quality_checks (case_id, result) values (c1, 'pass');
  perform public.advance_case(c1, 'fitting');
  perform tests.eq('T55c technician moved case through production/QC/fitting', (select status from public.cases where id = c1), 'fitting');
  perform tests.expect_error('T55d technician cannot unassigned-case advance (case 2)',
    format('select public.advance_case(%L, %L)', c2, 'cancelled'), '42501');
  perform tests.logout();

  -- ---- measurements and technical assessments ----
  perform tests.login(tech);
  insert into public.measurements (case_id, label, value, unit, side) values (c1, 'Thigh circumference', 52.5, 'cm', 'left');
  perform tests.eq('T56a measurement author server-side', (select author_id from public.measurements), tech);
  perform tests.expect_error('T56b measurement on unassigned case denied',
    format('insert into public.measurements (case_id, label, value, unit) values (%L, %L, 1, %L)', c2, 'x', 'cm'), '42501');
  perform tests.expect_error('T56c invalid unit rejected',
    format('insert into public.measurements (case_id, label, value, unit) values (%L, %L, 1, %L)', c1, 'x', 'miles'), '23514');
  perform tests.expect_error('T56d measurements are append-only', 'update public.measurements set value = 1', '42501');
  insert into public.assessments (patient_id, assessment_type, findings, case_id) values (p1, 'technical', 'Socket fit ok', c1);
  perform tests.expect_error('T56e technician cannot write a clinical assessment',
    format('insert into public.assessments (patient_id, assessment_type, findings, case_id) values (%L, %L, %L, %L)', p1, 'clinical', 'x', c1), '42501');
  perform tests.expect_error('T56f technical assessment on unassigned case denied',
    format('insert into public.assessments (patient_id, assessment_type, findings, case_id) values (%L, %L, %L, %L)', p2, 'technical', 'x', c2), '42501');
  perform tests.expect_error('T56g technical assessment with mismatched patient denied',
    format('insert into public.assessments (patient_id, assessment_type, findings, case_id) values (%L, %L, %L, %L)', p2, 'technical', 'x', c1), '42501');
  perform tests.eq('T56h technician reads own technical assessment', (select count(*) from public.assessments)::int, 1);
  perform tests.logout();

  perform tests.login(doc);
  perform tests.eq('T57a linked doctor reads case of own patient', (select count(*) from public.cases)::int, 1);
  perform tests.eq('T57b doctor sees measurements of linked patient case', (select count(*) from public.measurements)::int, 1);
  perform tests.eq('T57c doctor sees case events', (select count(*) from public.case_events)::int >= 5, true);
  perform tests.expect_error('T57d doctor cannot write measurements',
    format('insert into public.measurements (case_id, label, value, unit) values (%L, %L, 1, %L)', c1, 'x', 'cm'), '42501');
  perform tests.logout();
  perform tests.login(mgmt);
  perform tests.eq('T57e management sees all cases', (select count(*) from public.cases)::int, 2);
  perform tests.eq('T57f management reads measurements', (select count(*) from public.measurements)::int, 1);
  perform tests.expect_error('T57g management cannot write measurements',
    format('insert into public.measurements (case_id, label, value, unit) values (%L, %L, 1, %L)', c1, 'x', 'cm'), '42501');
  perform tests.logout();

  -- ---- patients ----
  perform tests.login(pat1);
  perform tests.eq('T58a patient sees only own case', (select count(*) from public.cases)::int, 1);
  perform tests.eq('T58b patient sees no case events', (select count(*) from public.case_events)::int, 0);
  perform tests.eq('T58c patient sees no measurements', (select count(*) from public.measurements)::int, 0);
  perform tests.eq('T58d patient sees no assignments', (select count(*) from public.case_assignments)::int, 0);
  perform tests.eq('T58e patient cannot read technical assessments', (select count(*) from public.assessments)::int, 0);
  perform tests.logout();
  perform tests.login(pat2);
  perform tests.eq('T58f other patient sees only own case', (select id from public.cases), c2);
  perform tests.logout();
  perform tests.anon();
  perform tests.expect_error('T58g anon denied cases', 'select * from public.cases', '42501');
  perform tests.logout();

  -- ---- unassignment removes access; closed cases are read-only ----
  perform tests.login(mgmt);
  update public.case_assignments set ended_at = now() where id = asg;
  perform tests.eq('T59a unassignment event written', (select count(*) from public.case_events where case_id = c1 and event_type = 'unassignment')::int, 1);
  perform tests.logout();
  perform tests.login(tech);
  perform tests.eq('T59b technician loses case access after unassignment', (select count(*) from public.cases)::int, 0);
  perform tests.eq('T59c ...and patient access', (select count(*) from public.patients)::int, 0);
  perform tests.eq('T59d ...and measurements', (select count(*) from public.measurements)::int, 0);
  perform tests.logout();
  update public.cases set status = 'closed' where id = c1;
  perform tests.login(admin_id);
  perform tests.expect_error('T59e measurement on closed case rejected',
    format('insert into public.measurements (case_id, label, value, unit) values (%L, %L, 1, %L)', c1, 'x', 'cm'), '23514');
  perform tests.expect_error('T59f cannot assign technician to closed case',
    format('insert into public.case_assignments (case_id, technician_id) values (%L, %L)', c1, tech), '23514');
  perform public.advance_case(c1, 'follow_up', 'reopen');
  perform tests.eq('T59g authorized staff can reopen a closed case', (select status from public.cases where id = c1), 'follow_up');
  perform tests.expect_error('T59h case events are immutable', 'update public.case_events set note = ''x''', '42501');
  perform tests.logout();

  select count(*) into n from public.audit_logs where entity_type in ('cases','case_assignments','measurements');
  perform tests.eq('T59i case operations audited', n >= 8, true);
end $$;
select 'PHASE 3 CASE WORKFLOW TESTS PASSED' as result;
