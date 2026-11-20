-- Phase 7 finance (D-027). Reuses approved quotations created by test 07.
do $$
declare
  admin_id uuid := '00000000-0000-0000-0000-0000000000a1';
  mgmt uuid := '00000000-0000-0000-0000-0000000000a2';
  tech uuid := '00000000-0000-0000-0000-0000000000a3';
  doc  uuid := '00000000-0000-0000-0000-0000000000a4';
  pat1 uuid := '00000000-0000-0000-0000-0000000000a5';
  qa uuid; qb uuid; qn uuid; inv uuid; inv2 uuid; s record; amt numeric; cur text;
begin
  select id into qa from public.quotations where status = 'approved' order by quotation_no limit 1;
  select id into qb from public.quotations where status = 'approved' and id <> qa order by quotation_no limit 1;
  select id into qn from public.quotations where status <> 'approved' limit 1;
  perform tests.eq('T90a fixtures: two approved quotations and a non-approved one', qa is not null and qb is not null and qn is not null, true);
  select (snapshot->>'total')::numeric, snapshot->>'currency' into amt, cur from public.quotations where id = qa;

  perform tests.login(tech);
  perform tests.expect_error('T90b technician cannot issue invoices', format('select public.issue_invoice(%L)', qa), '42501');
  perform tests.eq('T90c technician sees no invoices', (select count(*) from public.invoices)::int, 0);
  perform tests.logout();
  perform tests.login(doc);
  perform tests.expect_error('T90d doctor cannot issue invoices', format('select public.issue_invoice(%L)', qa), '42501');
  perform tests.eq('T90e doctor sees no payments (RLS)', (select count(*) from public.payments)::int, 0);
  perform tests.logout();
  perform tests.login(pat1);
  perform tests.eq('T90f patient sees no invoices', (select count(*) from public.invoices)::int, 0);
  perform tests.eq('T90g patient sees no expenses', (select count(*) from public.expenses)::int, 0);
  perform tests.logout();
  perform tests.anon();
  perform tests.expect_error('T90h anon denied invoices', 'select * from public.invoices', '42501');
  perform tests.expect_error('T90i anon cannot issue', format('select public.issue_invoice(%L)', qa), '42501');
  perform tests.logout();

  perform tests.login(mgmt);
  perform tests.expect_error('T91a invoice refused for a non-approved quotation', format('select public.issue_invoice(%L)', qn), '23514');
  inv := public.issue_invoice(qa);
  perform tests.eq('T91b amount and currency copied from the snapshot',
    (select (amount = amt)::text || '/' || (currency = cur)::text from public.invoices where id = inv), 'true/true');
  perform tests.eq('T91c invoice patient matches the case patient',
    (select (i.patient_id = c.patient_id)::text from public.invoices i join public.cases c on c.id = i.case_id where i.id = inv), 'true');
  perform tests.expect_error('T91d one invoice per quotation', format('select public.issue_invoice(%L)', qa), '23505');
  perform tests.expect_error('T91e direct invoice insert denied',
    format('insert into public.invoices (quotation_id, case_id, patient_id, currency, amount) select id, case_id, (select patient_id from public.cases c where c.id = case_id), %L, 1 from public.quotations where id = %L', 'USD', qb), '42501');
  perform tests.expect_error('T91f direct invoice update denied', format('update public.invoices set amount = 1 where id = %L', inv), '42501');
  perform tests.expect_error('T91g invoice delete denied', 'delete from public.invoices', '42501');
  perform tests.logout();
  perform tests.expect_error('T91h invoice figures immutable even for superuser', format('update public.invoices set amount = 1 where id = %L', inv), '23514');

  perform tests.login(mgmt);
  perform tests.expect_error('T92a payment above balance rejected',
    format('insert into public.payments (invoice_id, amount, method) values (%L, %s, %L)', inv, amt + 0.01, 'cash'), '23514');
  perform tests.expect_error('T92b zero payment rejected', format('insert into public.payments (invoice_id, amount, method) values (%L, 0, %L)', inv, 'cash'), '23514');
  perform tests.expect_error('T92c unknown method rejected', format('insert into public.payments (invoice_id, amount, method) values (%L, 1, %L)', inv, 'barter'), '23514');
  insert into public.payments (invoice_id, amount, method, currency) values (inv, 100, 'cash', 'ZZZ');
  perform tests.eq('T92d payment currency forced to the invoice currency and creator set',
    (select (currency = cur)::text || '/' || (created_by = mgmt)::text from public.payments where invoice_id = inv), 'true/true');
  select * into s from public.invoice_summary(inv);
  perform tests.eq('T92e summary after partial payment', s.paid::text || '/' || s.balance::text, '100.00/' || (amt - 100)::text);
  perform tests.expect_error('T92f invoice with payments cannot be voided', format('select public.void_invoice(%L, %L)', inv, 'x'), '23514');
  insert into public.payments (invoice_id, amount, method, reference) values (inv, amt - 100, 'bank_transfer', 'REF-1');
  select * into s from public.invoice_summary(inv);
  perform tests.eq('T92g fully paid balance is zero', s.balance, 0::numeric);
  perform tests.expect_error('T92h no payment after full settlement', format('insert into public.payments (invoice_id, amount, method) values (%L, 0.01, %L)', inv, 'cash'), '23514');
  perform tests.expect_error('T92i payments are append-only (update)', 'update public.payments set amount = 1', '42501');
  perform tests.expect_error('T92j payments are append-only (delete)', 'delete from public.payments', '42501');
  perform tests.logout();
  perform tests.expect_error('T92k payments immutable even for superuser', 'update public.payments set amount = 1', 'P0001');

  perform tests.login(admin_id);
  inv2 := public.issue_invoice(qb);
  perform tests.expect_error('T93a void requires a reason', format('select public.void_invoice(%L, %L)', inv2, '  '), '23514');
  perform public.void_invoice(inv2, 'issued by mistake');
  perform tests.eq('T93b invoice voided with reason', (select status || '/' || void_reason from public.invoices where id = inv2), 'void/issued by mistake');
  perform tests.expect_error('T93c cannot void twice', format('select public.void_invoice(%L, %L)', inv2, 'again'), '23514');
  perform tests.expect_error('T93d cannot pay a void invoice', format('insert into public.payments (invoice_id, amount, method) values (%L, 1, %L)', inv2, 'cash'), '23514');
  perform tests.logout();
  perform tests.login(tech);
  perform tests.expect_error('T93e technician cannot void', format('select public.void_invoice(%L, %L)', inv, 'x'), '42501');
  perform tests.expect_error('T93f technician cannot add expenses', 'insert into public.expenses (category, amount, currency, incurred_on) values (''x'', 1, ''USD'', current_date)', '42501');
  perform tests.logout();

  perform tests.login(mgmt);
  insert into public.expenses (category, description, amount, currency, incurred_on) values ('Materials', 'test', 50, 'USD', current_date);
  perform tests.eq('T94a expense recorded with creator', (select (created_by = mgmt)::text from public.expenses limit 1), 'true');
  perform tests.expect_error('T94b negative expense rejected', 'insert into public.expenses (category, amount, currency, incurred_on) values (''x'', -1, ''USD'', current_date)', '23514');
  perform tests.expect_error('T94c lowercase currency rejected', 'insert into public.expenses (category, amount, currency, incurred_on) values (''x'', 1, ''usd'', current_date)', '23514');
  perform tests.expect_error('T94d expenses are append-only', 'update public.expenses set amount = 1', '42501');
  perform tests.logout();
  perform tests.eq('T94e finance operations audited',
    (select count(*) from public.audit_logs where entity_type in ('invoices','payments','expenses'))::int >= 6, true);
end $$;
select 'PHASE 7 DB TESTS PASSED' as result;
