-- Depends on fixtures from 01/02: a1 admin, a2 mgmt, a3 tech, a4 doctor, a5/a6 patients.
do $$
declare
  admin_id uuid := '00000000-0000-0000-0000-0000000000a1';
  mgmt uuid := '00000000-0000-0000-0000-0000000000a2';
  tech uuid := '00000000-0000-0000-0000-0000000000a3';
  doc  uuid := '00000000-0000-0000-0000-0000000000a4';
  pat1 uuid := '00000000-0000-0000-0000-0000000000a5';
  pat2 uuid := '00000000-0000-0000-0000-0000000000a6';
  p1 uuid; p2 uuid; d1 uuid; rep uuid; rx uuid; rel uuid; n int;
begin
  select id into p1 from public.patients where user_id = pat1;
  select id into p2 from public.patients where user_id = pat2;
  select id into d1 from public.doctors where user_id = doc;
  -- trusted setup: doctor active again, active link to p1 only
  update public.doctors set is_active = true where id = d1;
  update public.doctor_patient_relationships set ended_at = now() where doctor_id = d1 and ended_at is null;
  insert into public.doctor_patient_relationships (doctor_id, patient_id) values (d1, p1) returning id into rel;

  -- Doctor writes for linked patient
  perform tests.login(doc);
  insert into public.medical_records (patient_id, record_type, summary) values (p1, 'diagnosis', 'Test diagnosis');
  insert into public.clinical_notes (patient_id, body) values (p1, 'INTERNAL note');
  insert into public.assessments (patient_id, assessment_type, findings) values (p1, 'clinical', 'Test findings');
  insert into public.prescriptions (patient_id, doctor_id, device_type) values (p1, d1, 'Test device') returning id into rx;
  insert into public.shareable_reports (patient_id, title, body) values (p1, 'Report', 'Body') returning id into rep;
  perform tests.eq('T30a author set server-side', (select author_id from public.clinical_notes), doc);
  perform tests.expect_error('T30b doctor cannot write for unlinked patient',
    format('insert into public.clinical_notes (patient_id, body) values (%L, %L)', p2, 'x'), '42501');
  perform tests.expect_error('T30c doctor cannot add technical assessment',
    format('insert into public.assessments (patient_id, assessment_type, findings) values (%L, %L, %L)', p1, 'technical', 'x'), '42501');
  perform tests.expect_error('T30d prescription must carry own doctor id (other doctor id)',
    format('insert into public.prescriptions (patient_id, doctor_id, device_type) values (%L, %L, %L)', p1, gen_random_uuid(), 'x'));
  perform tests.eq('T30e doctor reads own patient notes', (select count(*) from public.clinical_notes)::int, 1);
  perform tests.expect_error('T30f clinical notes are append-only (update)', 'update public.clinical_notes set body = ''edited''', '42501');
  perform tests.expect_error('T30g clinical notes cannot be deleted', 'delete from public.clinical_notes', '42501');
  update public.prescriptions set status = 'cancelled' where id = rx;
  perform tests.eq('T30h doctor can cancel prescription', (select status from public.prescriptions where id = rx), 'cancelled');
  perform tests.logout();

  -- Patient: nothing internal; only published reports
  perform tests.login(pat1);
  perform tests.eq('T31a patient sees 0 medical records', (select count(*) from public.medical_records)::int, 0);
  perform tests.eq('T31b patient sees 0 clinical notes', (select count(*) from public.clinical_notes)::int, 0);
  perform tests.eq('T31c patient sees 0 assessments', (select count(*) from public.assessments)::int, 0);
  perform tests.eq('T31d patient sees 0 prescriptions', (select count(*) from public.prescriptions)::int, 0);
  perform tests.eq('T31e patient does not see DRAFT report', (select count(*) from public.shareable_reports)::int, 0);
  perform tests.expect_error('T31f patient cannot write reports',
    format('insert into public.shareable_reports (patient_id, title, body) values (%L, %L, %L)', p1, 'x', 'x'), '42501');
  perform tests.logout();

  -- Doctor publishes; patient sees only that
  perform tests.login(doc);
  update public.shareable_reports set status = 'published' where id = rep;
  perform tests.logout();
  perform tests.login(pat1);
  perform tests.eq('T32a patient sees published own report', (select count(*) from public.shareable_reports)::int, 1);
  perform tests.eq('T32b published_at set', (select published_at is not null from public.shareable_reports), true);
  perform tests.logout();
  perform tests.login(pat2);
  perform tests.eq('T32c other patient sees 0 reports', (select count(*) from public.shareable_reports)::int, 0);
  perform tests.logout();
  perform tests.login(doc);
  perform tests.expect_error('T32d published report body is immutable',
    format('update public.shareable_reports set body = %L where id = %L', 'changed', rep), '23514');
  update public.shareable_reports set status = 'withdrawn' where id = rep;
  perform tests.logout();
  perform tests.login(pat1);
  perform tests.eq('T32e withdrawn report hidden from patient', (select count(*) from public.shareable_reports)::int, 0);
  perform tests.logout();

  -- Management and technician: no clinical access at all
  perform tests.login(mgmt);
  perform tests.eq('T33a management READS notes (D-019)', (select count(*) from public.clinical_notes)::int, 1);
  perform tests.eq('T33b management READS medical records', (select count(*) from public.medical_records)::int, 1);
  perform tests.eq('T33c management READS reports', (select count(*) from public.shareable_reports)::int, 1);
  perform tests.eq('T33d management READS prescriptions', (select count(*) from public.prescriptions)::int, 1);
  perform tests.eq('T33d2 management READS assessments', (select count(*) from public.assessments)::int, 1);
  perform tests.expect_error('T33d3 management cannot write medical records',
    format('insert into public.medical_records (patient_id, record_type, summary) values (%L, %L, %L)', p1, 'other', 'x'), '42501');
  perform tests.expect_error('T33d4 management cannot write assessments',
    format('insert into public.assessments (patient_id, assessment_type, findings) values (%L, %L, %L)', p1, 'clinical', 'x'), '42501');
  perform tests.expect_error('T33d5 management cannot write prescriptions',
    format('insert into public.prescriptions (patient_id, doctor_id, device_type) values (%L, %L, %L)', p1, d1, 'x'), '42501');
  perform tests.expect_error('T33d6 management cannot write reports',
    format('insert into public.shareable_reports (patient_id, title, body) values (%L, %L, %L)', p1, 'x', 'x'), '42501');
  perform tests.expect_error('T33e management cannot write notes',
    format('insert into public.clinical_notes (patient_id, body) values (%L, %L)', p1, 'x'), '42501');
  insert into public.referrals (patient_id, referring_doctor_id, reason) values (p1, d1, 'Test referral') returning id into rel;
  perform tests.eq('T33f management manages referrals', (select count(*) from public.referrals)::int, 1);
  perform tests.logout();
  perform tests.login(doc);
  perform tests.eq('T33g referring doctor sees own referral', (select count(*) from public.referrals)::int, 1);
  perform tests.logout();
  perform tests.login(tech);
  perform tests.eq('T34a technician sees 0 notes', (select count(*) from public.clinical_notes)::int, 0);
  perform tests.eq('T34b technician sees 0 assessments', (select count(*) from public.assessments)::int, 0);
  perform tests.eq('T34c technician sees 0 referrals', (select count(*) from public.referrals)::int, 0);
  perform tests.logout();

  perform tests.anon();
  perform tests.expect_error('T35a anon denied clinical_notes', 'select * from public.clinical_notes', '42501');
  perform tests.expect_error('T35b anon denied shareable_reports', 'select * from public.shareable_reports', '42501');
  perform tests.logout();

  -- Admin sees everything; link end removes doctor access
  perform tests.login(admin_id);
  perform tests.eq('T36a admin sees all notes', (select count(*) from public.clinical_notes)::int, 1);
  perform tests.eq('T36b admin sees reports incl. withdrawn', (select count(*) from public.shareable_reports)::int, 1);
  perform tests.logout();
  update public.doctor_patient_relationships set ended_at = now() where doctor_id = d1 and ended_at is null;
  perform tests.login(doc);
  perform tests.eq('T37a doctor loses clinical access when link ends', (select count(*) from public.clinical_notes)::int, 0);
  perform tests.eq('T37b ...and prescriptions', (select count(*) from public.prescriptions)::int, 0);
  perform tests.logout();

  select count(*) into n from public.audit_logs
   where entity_type in ('medical_records','clinical_notes','assessments','prescriptions','shareable_reports','referrals');
  perform tests.eq('T38 clinical operations are audited', n >= 9, true);
end $$;
select 'PHASE 2 CLINICAL DB TESTS PASSED' as result;
