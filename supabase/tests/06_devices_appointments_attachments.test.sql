-- Fixtures from 01-05: a1 admin, a2 mgmt, a3 tech, a4 doctor, a5/a6 patients.
do $$
declare
  mgmt uuid := '00000000-0000-0000-0000-0000000000a2';
  tech uuid := '00000000-0000-0000-0000-0000000000a3';
  doc  uuid := '00000000-0000-0000-0000-0000000000a4';
  pat1 uuid := '00000000-0000-0000-0000-0000000000a5';
  pat2 uuid := '00000000-0000-0000-0000-0000000000a6';
  p1 uuid; p2 uuid; d1 uuid; c1 uuid; c2 uuid; dev uuid; ap uuid; att_int uuid; att_sh uuid;
  path_int text; path_sh text; path_p2 text; fu uuid; n int;
begin
  select id into p1 from public.patients where user_id = pat1;
  select id into p2 from public.patients where user_id = pat2;
  select id into d1 from public.doctors where user_id = doc;
  select id into c1 from public.cases where patient_id = p1 limit 1;   -- now in follow_up (reopened in test 05)
  select id into c2 from public.cases where patient_id = p2 limit 1;   -- still assessment
  -- trusted setup: doctor linked to p1, technician assigned to c1 again, c1 back in 'fitting'
  update public.doctor_patient_relationships set ended_at = now() where doctor_id = d1 and ended_at is null;
  insert into public.doctor_patient_relationships (doctor_id, patient_id) values (d1, p1);
  update public.cases set status = 'fitting' where id = c1;
  insert into public.case_assignments (case_id, technician_id) values (c1, tech);

  -- ---- devices ----
  perform tests.login(tech);
  insert into public.devices (case_id, device_type, side, description) values (c1, 'Transtibial prosthesis', 'left', 'design notes') returning id into dev;
  insert into public.device_components (device_id, name) values (dev, 'Socket');
  perform tests.eq('T60a created_by server-side', (select created_by from public.devices where id = dev), tech);
  perform tests.expect_error('T60b technician cannot add device to unassigned case',
    format('insert into public.devices (case_id, device_type) values (%L, %L)', c2, 'x'), '42501');
  perform tests.expect_error('T60c invalid side rejected',
    format('insert into public.devices (case_id, device_type, side) values (%L, %L, %L)', c1, 'x', 'up'), '23514');
  perform tests.logout();
  perform tests.login(doc);
  perform tests.eq('T60d linked doctor reads device', (select count(*) from public.devices)::int, 1);
  perform tests.eq('T60e ...and components', (select count(*) from public.device_components)::int, 1);
  perform tests.expect_error('T60f doctor cannot add devices',
    format('insert into public.devices (case_id, device_type) values (%L, %L)', c1, 'x'), '42501');
  perform tests.logout();
  perform tests.login(pat1);
  perform tests.eq('T60g patient sees no devices', (select count(*) from public.devices)::int, 0);
  perform tests.logout();

  -- ---- appointments ----
  perform tests.login(mgmt);
  insert into public.appointments (patient_id, case_id, appointment_type, scheduled_at) values (p1, c1, 'fitting', now() + interval '2 days') returning id into ap;
  insert into public.appointments (patient_id, appointment_type, scheduled_at) values (p2, 'assessment', now() + interval '3 days');
  perform tests.expect_error('T61a appointment case must belong to the patient',
    format('insert into public.appointments (patient_id, case_id, appointment_type, scheduled_at) values (%L, %L, %L, now())', p2, c1, 'fitting'), '23514');
  perform tests.eq('T61b management sees all appointments', (select count(*) from public.appointments)::int, 2);
  perform tests.logout();
  perform tests.login(doc);
  perform tests.eq('T61c doctor sees only linked patient appointments', (select count(*) from public.appointments)::int, 1);
  insert into public.appointments (patient_id, appointment_type, scheduled_at) values (p1, 'consultation', now() + interval '5 days');
  perform tests.expect_error('T61d doctor cannot schedule for unlinked patient',
    format('insert into public.appointments (patient_id, appointment_type, scheduled_at) values (%L, %L, now())', p2, 'consultation'), '42501');
  perform tests.logout();
  perform tests.login(pat1);
  perform tests.eq('T61e patient sees own appointments only', (select count(*) from public.appointments)::int, 2);
  perform tests.expect_error('T61f patient cannot schedule',
    format('insert into public.appointments (patient_id, appointment_type, scheduled_at) values (%L, %L, now())', p1, 'other'), '42501');
  update public.appointments set status = 'cancelled' where id = ap;
  perform tests.eq('T61g patient cannot change appointments (0 rows)', (select status from public.appointments where id = ap), 'scheduled');
  perform tests.logout();
  perform tests.login(tech);
  perform tests.eq('T61h technician sees appointments of assigned case only', (select count(*) from public.appointments)::int, 1);
  perform tests.expect_error('T61i technician cannot schedule',
    format('insert into public.appointments (patient_id, case_id, appointment_type, scheduled_at) values (%L, %L, %L, now())', p1, c1, 'fitting'), '42501');
  perform tests.logout();
  perform tests.login(mgmt);
  update public.appointments set status = 'completed' where id = ap;
  perform tests.eq('T61j management updates appointment status', (select status from public.appointments where id = ap), 'completed');
  perform tests.logout();

  -- ---- follow-ups (only after delivery) ----
  perform tests.login(tech);
  perform tests.expect_error('T62a follow-up before delivery rejected',
    format('insert into public.follow_ups (case_id, due_date) values (%L, current_date + 30)', c1), '23514');
  perform tests.logout();
  update public.cases set status = 'delivered' where id = c1;
  perform tests.login(tech);
  insert into public.follow_ups (case_id, due_date, technical_feedback) values (c1, current_date + 30, 'check socket') returning id into fu;
  update public.follow_ups set status = 'done', device_issues = 'none' where id = fu;
  perform tests.eq('T62b assigned technician records follow-up', (select status from public.follow_ups where id = fu), 'done');
  perform tests.eq('T62c author server-side', (select author_id from public.follow_ups where id = fu), tech);
  perform tests.logout();
  perform tests.login(doc);
  perform tests.eq('T62d doctor reads follow-ups of linked patient', (select count(*) from public.follow_ups)::int, 1);
  perform tests.expect_error('T62e doctor cannot write follow-ups',
    format('insert into public.follow_ups (case_id, due_date) values (%L, current_date)', c1), '42501');
  perform tests.logout();
  perform tests.login(pat1);
  perform tests.eq('T62f patient sees no follow-up notes', (select count(*) from public.follow_ups)::int, 0);
  perform tests.logout();

  -- ---- attachments: metadata + private storage ----
  path_int := format('patients/%s/%s.jpg', p1, gen_random_uuid());
  path_sh  := format('patients/%s/%s.pdf', p1, gen_random_uuid());
  path_p2  := format('patients/%s/%s.png', p2, gen_random_uuid());
  perform tests.login(tech);
  insert into public.attachments (patient_id, case_id, category, storage_path, file_name, mime_type, size_bytes)
    values (p1, c1, 'photo', path_int, 'stump.jpg', 'image/jpeg', 120000) returning id into att_int;
  perform tests.eq('T63a uploader set server-side', (select uploaded_by from public.attachments where id = att_int), tech);
  perform tests.expect_error('T63b technician cannot attach to unassigned case/patient',
    format('insert into public.attachments (patient_id, case_id, category, storage_path, file_name, mime_type, size_bytes) values (%L, %L, %L, %L, %L, %L, 1)', p2, c2, 'photo', path_p2, 'a.png', 'image/png'), '42501');
  perform tests.expect_error('T63c technician cannot attach without a case',
    format('insert into public.attachments (patient_id, category, storage_path, file_name, mime_type, size_bytes) values (%L, %L, %L, %L, %L, 1)', p1, 'photo', format('patients/%s/%s.png', p1, gen_random_uuid()), 'a.png', 'image/png'), '42501');
  perform tests.expect_error('T63d executable/unsupported mime rejected',
    format('insert into public.attachments (patient_id, case_id, category, storage_path, file_name, mime_type, size_bytes) values (%L, %L, %L, %L, %L, %L, 1)', p1, c1, 'document', format('patients/%s/%s.pdf', p1, gen_random_uuid()), 'x.exe', 'application/x-msdownload'), '23514');
  perform tests.expect_error('T63e oversize file rejected',
    format('insert into public.attachments (patient_id, case_id, category, storage_path, file_name, mime_type, size_bytes) values (%L, %L, %L, %L, %L, %L, 99999999)', p1, c1, 'document', format('patients/%s/%s.pdf', p1, gen_random_uuid()), 'x.pdf', 'application/pdf'), '23514');
  perform tests.expect_error('T63f path traversal / user-chosen path rejected',
    format('insert into public.attachments (patient_id, case_id, category, storage_path, file_name, mime_type, size_bytes) values (%L, %L, %L, %L, %L, %L, 1)', p1, c1, 'photo', 'patients/../../etc/passwd.jpg', 'x.jpg', 'image/jpeg'), '23514');
  perform tests.expect_error('T63g path must contain the same patient id',
    format('insert into public.attachments (patient_id, case_id, category, storage_path, file_name, mime_type, size_bytes) values (%L, %L, %L, %L, %L, %L, 1)', p1, c1, 'photo', path_p2, 'x.png', 'image/png'), '23514');
  -- storage: upload allowed only for a registered path by its uploader
  insert into storage.objects (bucket_id, name) values ('attachments', path_int);
  perform tests.expect_error('T63h object upload without metadata row denied',
    format('insert into storage.objects (bucket_id, name) values (%L, %L)', 'attachments', format('patients/%s/%s.jpg', p1, gen_random_uuid())), '42501');
  update storage.objects set name = name || 'x';
  perform tests.eq('T63i objects cannot be renamed (RLS: 0 rows)', (select count(*) from storage.objects where name = path_int)::int, 1);
  delete from storage.objects;
  perform tests.eq('T63j objects cannot be deleted (RLS: 0 rows)', (select count(*) from storage.objects where name = path_int)::int, 1);
  perform tests.logout();

  -- shared report by management for the patient
  perform tests.login(mgmt);
  insert into public.attachments (patient_id, case_id, category, visibility, storage_path, file_name, mime_type, size_bytes)
    values (p1, c1, 'report', 'shared', path_sh, 'report.pdf', 'application/pdf', 5000) returning id into att_sh;
  insert into storage.objects (bucket_id, name) values ('attachments', path_sh);
  perform tests.eq('T64a management reads all attachment metadata', (select count(*) from public.attachments)::int, 2);
  perform tests.eq('T64b management can read both objects', (select count(*) from storage.objects)::int, 2);
  perform tests.logout();

  perform tests.login(pat1);
  perform tests.eq('T65a patient sees only SHARED attachment metadata', (select count(*) from public.attachments)::int, 1);
  perform tests.eq('T65b patient reads only shared object', (select name from storage.objects), path_sh);
  perform tests.expect_error('T65c patient cannot upload',
    format('insert into public.attachments (patient_id, category, storage_path, file_name, mime_type, size_bytes) values (%L, %L, %L, %L, %L, 1)', p1, 'document', format('patients/%s/%s.pdf', p1, gen_random_uuid()), 'a.pdf', 'application/pdf'), '42501');
  perform tests.logout();
  perform tests.login(pat2);
  perform tests.eq('T65d other patient sees no attachments', (select count(*) from public.attachments)::int, 0);
  perform tests.eq('T65e ...and no objects', (select count(*) from storage.objects)::int, 0);
  perform tests.logout();
  perform tests.login(doc);
  perform tests.eq('T66a linked doctor reads patient attachments (both)', (select count(*) from public.attachments)::int, 2);
  insert into public.attachments (patient_id, category, storage_path, file_name, mime_type, size_bytes)
    values (p1, 'document', format('patients/%s/%s.pdf', p1, gen_random_uuid()), 'referral.pdf', 'application/pdf', 100);
  perform tests.expect_error('T66b doctor cannot attach for unlinked patient',
    format('insert into public.attachments (patient_id, category, storage_path, file_name, mime_type, size_bytes) values (%L, %L, %L, %L, %L, 1)', p2, 'document', format('patients/%s/%s.pdf', p2, gen_random_uuid()), 'a.pdf', 'application/pdf'), '42501');
  perform tests.logout();
  perform tests.anon();
  perform tests.expect_error('T66c anon denied attachments', 'select * from public.attachments', '42501');
  perform tests.expect_error('T66d anon denied objects', 'select * from storage.objects', '42501');
  perform tests.logout();

  -- unassignment removes technician access to files
  update public.case_assignments set ended_at = now() where case_id = c1 and technician_id = tech and ended_at is null;
  perform tests.login(tech);
  perform tests.eq('T67a unassigned technician loses attachments', (select count(*) from public.attachments)::int, 0);
  perform tests.eq('T67b ...objects', (select count(*) from storage.objects)::int, 0);
  perform tests.eq('T67c ...devices', (select count(*) from public.devices)::int, 0);
  perform tests.logout();

  select count(*) into n from public.audit_logs where entity_type in ('devices','appointments','follow_ups','attachments');
  perform tests.eq('T67e operations audited', n >= 9, true);
end $$;
select 'PHASE 3B DB TESTS PASSED' as result;
