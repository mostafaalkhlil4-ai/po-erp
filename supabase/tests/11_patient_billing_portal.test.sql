-- D-029: patient sees only own approved quotations and own issued invoices.
do $$
declare
  pat1 uuid := '00000000-0000-0000-0000-0000000000a5';
  pat2 uuid := '00000000-0000-0000-0000-0000000000a6';
  tech uuid := '00000000-0000-0000-0000-0000000000a3';
  doc  uuid := '00000000-0000-0000-0000-0000000000a4';
  mgmt uuid := '00000000-0000-0000-0000-0000000000a2';
  exp1 int; exp2 int; inv1 int; inv2 int; r record;
begin
  select count(*) into exp1 from public.quotations q join public.cases c on c.id = q.case_id join public.patients p on p.id = c.patient_id where q.status = 'approved' and p.user_id = pat1;
  select count(*) into exp2 from public.quotations q join public.cases c on c.id = q.case_id join public.patients p on p.id = c.patient_id where q.status = 'approved' and p.user_id = pat2;
  select count(*) into inv1 from public.invoices i join public.patients p on p.id = i.patient_id where i.status = 'issued' and p.user_id = pat1;
  select count(*) into inv2 from public.invoices i join public.patients p on p.id = i.patient_id where i.status = 'issued' and p.user_id = pat2;
  perform tests.eq('T110a fixtures: some approved quotation and some issued invoice exist', (exp1 + exp2) > 0 and (inv1 + inv2) > 0, true);

  perform tests.login(pat1);
  perform tests.eq('T110b patient 1 sees exactly own approved quotations', (select count(*) from public.my_quotations())::int, exp1);
  perform tests.eq('T110c patient 1 sees exactly own issued (non-void) invoices', (select count(*) from public.my_invoices())::int, inv1);
  perform tests.eq('T110d patient still cannot read the quotations table', (select count(*) from public.quotations)::int, 0);
  perform tests.eq('T110e patient still cannot read the invoices table', (select count(*) from public.invoices)::int, 0);
  perform tests.logout();
  perform tests.login(pat2);
  perform tests.eq('T110f patient 2 sees exactly own approved quotations', (select count(*) from public.my_quotations())::int, exp2);
  perform tests.eq('T110g patient 2 sees exactly own issued (non-void) invoices', (select count(*) from public.my_invoices())::int, inv2);
  for r in select * from public.my_quotations() loop
    perform tests.eq('T110h snapshot exposed without internal columns', (r.snapshot ? 'total')::text || '/' || (r.snapshot ? 'created_by')::text, 'true/false');
  end loop;
  perform tests.logout();

  perform tests.login(tech);
  perform tests.eq('T111a technician gets nothing from my_quotations', (select count(*) from public.my_quotations())::int, 0);
  perform tests.eq('T111b technician gets nothing from my_invoices', (select count(*) from public.my_invoices())::int, 0);
  perform tests.logout();
  perform tests.login(doc);
  perform tests.eq('T111c doctor gets nothing from my_invoices', (select count(*) from public.my_invoices())::int, 0);
  perform tests.logout();
  perform tests.login(mgmt);
  perform tests.eq('T111d management is not a patient: nothing returned', (select count(*) from public.my_quotations())::int, 0);
  perform tests.logout();
  perform tests.anon();
  perform tests.expect_error('T111e anon cannot call my_quotations', 'select * from public.my_quotations()', '42501');
  perform tests.expect_error('T111f anon cannot call my_invoices', 'select * from public.my_invoices()', '42501');
  perform tests.logout();

end $$;
select 'PATIENT BILLING PORTAL TESTS PASSED' as result;
