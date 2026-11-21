-- D-029 (amended by 0013): patients see ONLY what staff manually shared: own approved quotations and own issued invoices.
do $$
declare
  pat1 uuid := '00000000-0000-0000-0000-0000000000a5';
  pat2 uuid := '00000000-0000-0000-0000-0000000000a6';
  tech uuid := '00000000-0000-0000-0000-0000000000a3';
  doc  uuid := '00000000-0000-0000-0000-0000000000a4';
  mgmt uuid := '00000000-0000-0000-0000-0000000000a2';
  exp1 int; exp2 int; inv1 int; inv2 int; r record; rq record; ri record;
begin
  select count(*) into exp1 from public.quotations q join public.cases c on c.id = q.case_id join public.patients p on p.id = c.patient_id where q.status = 'approved' and p.user_id = pat1;
  select count(*) into exp2 from public.quotations q join public.cases c on c.id = q.case_id join public.patients p on p.id = c.patient_id where q.status = 'approved' and p.user_id = pat2;
  select count(*) into inv1 from public.invoices i join public.patients p on p.id = i.patient_id where i.status = 'issued' and p.user_id = pat1;
  select count(*) into inv2 from public.invoices i join public.patients p on p.id = i.patient_id where i.status = 'issued' and p.user_id = pat2;
  perform tests.eq('T110a fixtures: some approved quotation and some issued invoice exist', (exp1 + exp2) > 0 and (inv1 + inv2) > 0, true);

  -- default: nothing is shared
  perform tests.login(pat1);
  perform tests.eq('T110b nothing shared yet: patient 1 sees no quotations', (select count(*) from public.my_quotations())::int, 0);
  perform tests.eq('T110c nothing shared yet: patient 1 sees no invoices', (select count(*) from public.my_invoices())::int, 0);
  perform tests.expect_error('T110d patient cannot share anything', format('select public.set_patient_visibility(%L, %L, true)', 'quotation', gen_random_uuid()), '42501');
  perform tests.expect_error('T110e patient cannot read the visibility table', 'select * from public.patient_visibility', '42501');
  perform tests.logout();

  perform tests.login(tech);
  perform tests.expect_error('T110f technician cannot share', format('select public.set_patient_visibility(%L, %L, true)', 'invoice', gen_random_uuid()), '42501');
  perform tests.logout();
  perform tests.login(doc);
  perform tests.expect_error('T110g doctor cannot share', format('select public.set_patient_visibility(%L, %L, true)', 'quotation', gen_random_uuid()), '42501');
  perform tests.logout();

  -- management shares everything that exists, manually
  perform tests.login(mgmt);
  perform tests.expect_error('T111a a non-approved quotation cannot be shared',
    format('select public.set_patient_visibility(%L, %L, true)', 'quotation', (select id from public.quotations where status <> 'approved' limit 1)), '23514');
  perform tests.expect_error('T111b a void invoice cannot be shared',
    format('select public.set_patient_visibility(%L, %L, true)', 'invoice', (select id from public.invoices where status = 'void' limit 1)), '23514');
  perform tests.expect_error('T111c invalid kind rejected', format('select public.set_patient_visibility(%L, %L, true)', 'payment', gen_random_uuid()), '23514');
  for rq in select id from public.quotations where status = 'approved' loop perform public.set_patient_visibility('quotation', rq.id, true); end loop;
  for ri in select id from public.invoices where status = 'issued' loop perform public.set_patient_visibility('invoice', ri.id, true); end loop;
  perform tests.eq('T111d management can read visibility flags', (select count(*) from public.visibility_of('quotation'))::int, exp1 + exp2);
  perform tests.logout();

  perform tests.login(pat1);
  perform tests.eq('T112a patient 1 sees exactly own shared approved quotations', (select count(*) from public.my_quotations())::int, exp1);
  perform tests.eq('T112b patient 1 sees exactly own shared issued invoices', (select count(*) from public.my_invoices())::int, inv1);
  perform tests.eq('T112c patient still cannot read the quotations table', (select count(*) from public.quotations)::int, 0);
  perform tests.eq('T112d patient still cannot read the invoices table', (select count(*) from public.invoices)::int, 0);
  perform tests.logout();
  perform tests.login(pat2);
  perform tests.eq('T112e patient 2 sees exactly own shared approved quotations', (select count(*) from public.my_quotations())::int, exp2);
  perform tests.eq('T112f patient 2 sees exactly own shared issued invoices', (select count(*) from public.my_invoices())::int, inv2);
  for r in select * from public.my_quotations() loop
    perform tests.eq('T112g snapshot exposed without internal columns', (r.snapshot ? 'total')::text || '/' || (r.snapshot ? 'created_by')::text, 'true/false');
  end loop;
  perform tests.logout();

  -- withdrawing hides it again
  perform tests.login(mgmt);
  for rq in select id from public.quotations where status = 'approved' loop perform public.set_patient_visibility('quotation', rq.id, false); end loop;
  perform tests.logout();
  perform tests.login(pat2);
  perform tests.eq('T113a withdrawn quotations disappear for the patient', (select count(*) from public.my_quotations())::int, 0);
  perform tests.eq('T113b shared invoices remain visible', (select count(*) from public.my_invoices())::int, inv2);
  perform tests.logout();

  perform tests.login(tech);
  perform tests.eq('T114a technician gets nothing from my_quotations', (select count(*) from public.my_quotations())::int, 0);
  perform tests.eq('T114b technician gets nothing from my_invoices', (select count(*) from public.my_invoices())::int, 0);
  perform tests.eq('T114c technician cannot read flags', (select count(*) from public.visibility_of('invoice'))::int, 0);
  perform tests.logout();
  perform tests.login(mgmt);
  perform tests.eq('T114d management is not a patient: nothing returned', (select count(*) from public.my_quotations())::int, 0);
  perform tests.logout();
  perform tests.anon();
  perform tests.expect_error('T114e anon cannot call my_quotations', 'select * from public.my_quotations()', '42501');
  perform tests.expect_error('T114f anon cannot call set_patient_visibility', format('select public.set_patient_visibility(%L, %L, true)', 'invoice', gen_random_uuid()), '42501');
  perform tests.logout();
  perform tests.eq('T114g sharing changes are audited', (select count(*) from public.audit_logs where entity_type = 'patient_visibility')::int >= 2, true);
end $$;
select 'PATIENT BILLING PORTAL TESTS PASSED' as result;
