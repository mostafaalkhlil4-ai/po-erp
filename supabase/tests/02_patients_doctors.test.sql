-- Depends on fixtures from 01_identity_rbac.test.sql (same DB, same user ids):
-- a1 admin, a2 management, a3 technician, a4 doctor, a5 patient1, a6 patient2.
do $$
declare
  admin_id uuid := '00000000-0000-0000-0000-0000000000a1';
  mgmt uuid := '00000000-0000-0000-0000-0000000000a2';
  tech uuid := '00000000-0000-0000-0000-0000000000a3';
  doc  uuid := '00000000-0000-0000-0000-0000000000a4';
  pat1 uuid := '00000000-0000-0000-0000-0000000000a5';
  pat2 uuid := '00000000-0000-0000-0000-0000000000a6';
  p1 uuid; p2 uuid; p3 uuid; d1 uuid; rel uuid; n int;
begin
  -- Management registers patients, a doctor, and the link
  perform tests.login(mgmt);
  insert into public.patients (full_name, date_of_birth, phone, user_id)
    values ('Test Patient One', '1990-01-01', '0100000001', pat1) returning id into p1;
  insert into public.patients (full_name, date_of_birth, phone, user_id)
    values ('Test Patient Two', '1985-05-05', '0100000002', pat2) returning id into p2;
  insert into public.patients (full_name, date_of_birth, phone)
    values ('Test Patient Three', '1970-03-03', '0100000003') returning id into p3;
  insert into public.doctors (full_name, specialty, user_id)
    values ('Dr Test', 'Orthopedics', doc) returning id into d1;
  insert into public.doctor_patient_relationships (doctor_id, patient_id) values (d1, p1) returning id into rel;
  perform tests.eq('T20a management created_by is set server-side',
    (select created_by from public.patients where id = p1), mgmt);
  perform tests.expect_error('T20b duplicate patient rejected',
    $q$insert into public.patients (full_name, date_of_birth, phone) values ('  test patient one ', '1990-01-01', '0100000001')$q$, '23505');
  perform tests.expect_error('T20c duplicate active link rejected',
    format('insert into public.doctor_patient_relationships (doctor_id, patient_id) values (%L, %L)', d1, p1), '23505');
  perform tests.expect_error('T20d management cannot delete patients',
    'delete from public.patients', '42501');
  perform tests.expect_error('T20e future birth date rejected',
    $q$insert into public.patients (full_name, date_of_birth) values ('Future Person', current_date + 1)$q$, '23514');
  perform tests.eq('T20f management sees all 3 patients', (select count(*) from public.patients)::int, 3);
  perform tests.logout();

  -- Doctor: linked patient only
  perform tests.login(doc);
  perform tests.eq('T21a doctor sees only linked patient', (select count(*) from public.patients)::int, 1);
  perform tests.eq('T21b doctor sees the right patient', (select id from public.patients), p1);
  perform tests.expect_error('T21c doctor cannot register patients',
    $q$insert into public.patients (full_name) values ('Doctor Made')$q$, '42501');
  update public.patients set full_name = 'Doctor Edit' where id = p1;
  perform tests.logout();
  perform tests.eq('T21d doctor update changed nothing (RLS)', (select full_name from public.patients where id = p1), 'Test Patient One');
  perform tests.login(doc);
  perform tests.eq('T21e doctor sees only own doctor row', (select count(*) from public.doctors)::int, 1);
  perform tests.expect_error('T21f doctor cannot create links',
    format('insert into public.doctor_patient_relationships (doctor_id, patient_id) values (%L, %L)', d1, p2), '42501');
  perform tests.logout();

  -- Patients: own record + their doctors
  perform tests.login(pat1);
  perform tests.eq('T22a patient1 sees only own record', (select count(*) from public.patients)::int, 1);
  perform tests.eq('T22b patient1 sees own linked doctor', (select count(*) from public.doctors)::int, 1);
  perform tests.expect_error('T22c patient cannot edit own demographics',
    $q$insert into public.patients (full_name) values ('Self Made')$q$, '42501');
  perform tests.logout();
  perform tests.login(pat2);
  perform tests.eq('T22d patient2 sees own record only', (select count(*) from public.patients)::int, 1);
  perform tests.eq('T22e patient2 has no doctors visible', (select count(*) from public.doctors)::int, 0);
  perform tests.eq('T22f patient2 sees no links', (select count(*) from public.doctor_patient_relationships)::int, 0);
  perform tests.logout();

  -- Technician has no patient access until case assignments exist (Phase 3)
  perform tests.login(tech);
  perform tests.eq('T23a technician sees 0 patients', (select count(*) from public.patients)::int, 0);
  perform tests.eq('T23b technician sees 0 doctors', (select count(*) from public.doctors)::int, 0);
  perform tests.logout();

  -- Anonymous
  perform tests.anon();
  perform tests.expect_error('T24a anon denied patients', 'select * from public.patients', '42501');
  perform tests.expect_error('T24b anon denied doctors', 'select * from public.doctors', '42501');
  perform tests.logout();

  -- Ending a link removes doctor access immediately
  perform tests.login(mgmt);
  update public.doctor_patient_relationships set ended_at = now() where id = rel;
  perform tests.logout();
  perform tests.login(doc);
  perform tests.eq('T25a doctor loses access after link ended', (select count(*) from public.patients)::int, 0);
  perform tests.logout();
  perform tests.login(pat1);
  perform tests.eq('T25b patient no longer sees ended-link doctor', (select count(*) from public.doctors)::int, 0);
  perform tests.logout();

  -- Inactive doctor loses access even with an active link
  perform tests.login(mgmt);
  insert into public.doctor_patient_relationships (doctor_id, patient_id) values (d1, p1);
  update public.doctors set is_active = false where id = d1;
  perform tests.logout();
  perform tests.login(doc);
  perform tests.eq('T25c deactivated doctor sees 0 patients', (select count(*) from public.patients)::int, 0);
  perform tests.logout();

  -- Audit trail
  perform tests.login(admin_id);
  select count(*) into n from public.audit_logs where entity_type in ('patients','doctors','doctor_patient_relationships');
  perform tests.eq('T26a patient/doctor/link changes are audited', n >= 8, true);
  perform tests.eq('T26b admin sees all patients', (select count(*) from public.patients)::int, 3);
  perform tests.logout();
end $$;
select 'PHASE 2 DB TESTS PASSED' as result;
