-- Synthetic catalog data exists ONLY inside this throwaway test DB. The migration seeds no products.
do $$
declare
  admin_id uuid := '00000000-0000-0000-0000-0000000000a1';
  mgmt uuid := '00000000-0000-0000-0000-0000000000a2';
  tech uuid := '00000000-0000-0000-0000-0000000000a3';
  doc  uuid := '00000000-0000-0000-0000-0000000000a4';
  pat1 uuid := '00000000-0000-0000-0000-0000000000a5';
  pat2 uuid := '00000000-0000-0000-0000-0000000000a6';
  p1 uuid; p2 uuid; c2 uuid; c3 uuid; c4 uuid; mf uuid; cat uuid;
  prod uuid; prod_eur uuid; prod_noprice uuid; prod_off uuid;
  q1 uuid; q0 uuid; q2 uuid; q3 uuid; q4 uuid; t record; snap jsonb; n int;
begin
  select id into p1 from public.patients where user_id = pat1;
  select id into p2 from public.patients where user_id = pat2;
  select id into c2 from public.cases where patient_id = p2 and status = 'assessment' limit 1;
  select id into mf from public.manufacturers where name = 'Ottobock';

  -- ---- catalog ----
  perform tests.eq('T70a exactly the three approved manufacturers',
    (select string_agg(name, ',' order by name) from public.manufacturers), 'Ottobock,PROTEOR,Össur');
  perform tests.eq('T70b migration seeded no products', (select count(*) from public.products)::int, 0);
  perform tests.login(mgmt);
  perform tests.expect_error('T70c nobody can add manufacturers via the API',
    $q$insert into public.manufacturers (name) values ('Invented Co')$q$, '42501');
  insert into public.product_categories (name) values ('Test category') returning id into cat;
  insert into public.products (manufacturer_id, category_id, name, sku) values (mf, cat, 'TEST PRODUCT A', 'TST-001') returning id into prod;
  insert into public.products (manufacturer_id, name, sku) values (mf, 'TEST PRODUCT EUR', 'TST-002') returning id into prod_eur;
  insert into public.products (manufacturer_id, name, sku) values (mf, 'TEST PRODUCT NO PRICE', 'TST-003') returning id into prod_noprice;
  insert into public.products (manufacturer_id, name, sku, is_active) values (mf, 'TEST PRODUCT OFF', 'TST-004', false) returning id into prod_off;
  perform tests.expect_error('T70d duplicate manufacturer sku rejected',
    format('insert into public.products (manufacturer_id, name, sku) values (%L, %L, %L)', mf, 'dup', 'TST-001'), '23505');
  insert into public.product_price_history (product_id, price, currency) values (prod, 100.00, 'USD'), (prod_eur, 80.00, 'EUR'), (prod_off, 10, 'USD');
  perform tests.expect_error('T70e lowercase currency rejected',
    format('insert into public.product_price_history (product_id, price, currency) values (%L, 1, %L)', prod, 'usd'), '23514');
  perform tests.expect_error('T70f negative price rejected',
    format('insert into public.product_price_history (product_id, price, currency) values (%L, -1, %L)', prod, 'USD'), '23514');
  perform tests.expect_error('T70g price history is append-only', 'update public.product_price_history set price = 1', '42501');
  perform tests.logout();

  -- read access: catalog visible to every role, prices only to staff
  perform tests.login(tech);
  perform tests.eq('T71a technician reads products', (select count(*) from public.products)::int, 4);
  perform tests.eq('T71b technician sees NO prices', (select count(*) from public.product_price_history)::int, 0);
  perform tests.expect_error('T71c technician cannot add products',
    format('insert into public.products (manufacturer_id, name, sku) values (%L, %L, %L)', mf, 'x', 'x'), '42501');
  perform tests.logout();
  perform tests.login(doc);
  perform tests.eq('T71d doctor sees no prices', (select count(*) from public.product_price_history)::int, 0);
  perform tests.logout();
  perform tests.login(pat1);
  perform tests.eq('T71e patient reads catalog', (select count(*) from public.products)::int, 4);
  perform tests.eq('T71f patient sees no prices', (select count(*) from public.product_price_history)::int, 0);
  perform tests.logout();
  perform tests.anon();
  perform tests.expect_error('T71g anon denied catalog', 'select * from public.products', '42501');
  perform tests.logout();

  -- ---- quotation guard on case stage ----
  perform tests.login(mgmt);
  insert into public.cases (patient_id, case_type) values (p2, 'orthotic') returning id into c4;
  perform tests.expect_error('T72a quotation not allowed while case is at assessment',
    format('insert into public.quotations (case_id, currency, tax_rate) values (%L, %L, 5)', c4, 'USD'), '42501');
  perform public.advance_case(c2, 'product_selection');
  perform tests.expect_error('T72b management cannot set a discount without permission (insert)',
    format('insert into public.quotations (case_id, currency, tax_rate, discount_percent) values (%L, %L, 10, 10)', c2, 'USD'), '42501');
  insert into public.quotations (case_id, currency, tax_rate) values (c2, 'USD', 10) returning id into q0;
  perform tests.eq('T72c draft starts at revision 1', (select revision from public.quotations where id = q0), 1);
  perform tests.expect_error('T72d empty quotation cannot be submitted',
    format('select public.submit_quotation(%L)', q0), '23514');
  delete from public.quotation_items where quotation_id = q0;   -- (nothing yet)
  update public.quotations set tax_rate = 12 where id = q0;
  update public.quotations set tax_rate = 10 where id = q0;

  -- ---- items and automatic pricing ----
  insert into public.quotation_items (quotation_id, item_type, product_id, description, quantity, unit_price)
    values (q0, 'product', prod, 'ignored text', 2, 1);
  perform tests.eq('T73a product price fetched automatically (client price ignored)',
    (select unit_price from public.quotation_items where quotation_id = q0), 100.00);
  perform tests.eq('T73b description comes from the catalog',
    (select description from public.quotation_items where quotation_id = q0), 'TEST PRODUCT A');
  perform tests.eq('T73c line total computed', (select line_total from public.quotation_items where quotation_id = q0), 200.00);
  insert into public.quotation_items (quotation_id, item_type, description, quantity, unit_price) values (q0, 'service', 'Fitting fee', 1, 50.00);
  perform tests.expect_error('T73d product item requires a product',
    format('insert into public.quotation_items (quotation_id, item_type, description, quantity, unit_price) values (%L, %L, %L, 1, 1)', q0, 'product', 'x'), '23514');
  perform tests.expect_error('T73e service item cannot reference a product',
    format('insert into public.quotation_items (quotation_id, item_type, product_id, description, quantity, unit_price) values (%L, %L, %L, %L, 1, 1)', q0, 'service', prod, 'x'), '23514');
  perform tests.expect_error('T73f currency mismatch rejected',
    format('insert into public.quotation_items (quotation_id, item_type, product_id, description, quantity) values (%L, %L, %L, %L, 1)', q0, 'product', prod_eur, 'x'), '23514');
  perform tests.expect_error('T73g product without a base price rejected',
    format('insert into public.quotation_items (quotation_id, item_type, product_id, description, quantity) values (%L, %L, %L, %L, 1)', q0, 'product', prod_noprice, 'x'), '23514');
  perform tests.expect_error('T73h inactive product rejected',
    format('insert into public.quotation_items (quotation_id, item_type, product_id, description, quantity) values (%L, %L, %L, %L, 1)', q0, 'product', prod_off, 'x'), '23514');
  perform tests.expect_error('T73i zero quantity rejected',
    format('insert into public.quotation_items (quotation_id, item_type, description, quantity, unit_price) values (%L, %L, %L, 0, 1)', q0, 'material', 'x'), '23514');
  perform tests.expect_error('T73j item price cannot be edited after creation',
    format('update public.quotation_items set unit_price = 1 where quotation_id = %L', q0), '42501');
  perform tests.expect_error('T73k currency cannot change once items exist',
    format('update public.quotations set currency = %L where id = %L', 'EUR', q0), '23514');
  perform tests.expect_error('T73l management cannot apply a discount',
    format('update public.quotations set discount_percent = 10 where id = %L', q0), '42501');
  select * into t from public.quotation_totals(q0);
  perform tests.eq('T74a totals without discount: subtotal', t.subtotal, 250.00::numeric);
  perform tests.eq('T74b total with 10% tax', t.total, 275.00::numeric);
  perform tests.logout();

  perform tests.login(admin_id);
  update public.quotations set discount_percent = 10 where id = q0;
  select * into t from public.quotation_totals(q0);
  perform tests.eq('T74c discount 10% of 250', t.discount_amount, 25.00::numeric);
  perform tests.eq('T74d tax on discounted amount (10% of 225)', t.tax_amount, 22.50::numeric);
  perform tests.eq('T74e final total', t.total, 247.50::numeric);
  perform tests.logout();

  -- ---- submit / approve ----
  perform tests.login(mgmt);
  perform public.submit_quotation(q0);
  perform tests.eq('T75a submitted', (select status from public.quotations where id = q0), 'submitted');
  perform tests.eq('T75b case moved to quotation', (select status from public.cases where id = c2), 'quotation');
  perform tests.eq('T75c submit stored a revision snapshot', (select count(*) from public.quotation_revisions where quotation_id = q0 and kind = 'submitted')::int, 1);
  perform tests.expect_error('T75d items locked after submit (insert)',
    format('insert into public.quotation_items (quotation_id, item_type, description, quantity, unit_price) values (%L, %L, %L, 1, 1)', q0, 'material', 'x'), '23514');
  perform tests.expect_error('T75e items locked after submit (delete)',
    format('delete from public.quotation_items where quotation_id = %L', q0), '23514');
  perform tests.expect_error('T75f header locked after submit',
    format('update public.quotations set tax_rate = 0 where id = %L', q0), '23514');
  perform tests.expect_error('T75g management cannot approve', format('select public.approve_quotation(%L)', q0), '42501');
  perform tests.expect_error('T75h management cannot reject', format('select public.reject_quotation(%L, %L)', q0, 'x'), '42501');
  perform tests.expect_error('T75i approval cannot bypass the snapshot via advance_case',
    format('select public.advance_case(%L, %L)', c2, 'approved'), '0A000');
  perform tests.expect_error('T75j status cannot be edited directly',
    format('update public.quotations set status = %L where id = %L', 'approved', q0), '42501');
  perform tests.logout();
  perform tests.anon();
  perform tests.expect_error('T75k anon cannot approve', format('select public.approve_quotation(%L)', q0), '42501');
  perform tests.logout();

  perform tests.login(admin_id);
  perform public.approve_quotation(q0);
  select snapshot into snap from public.quotations where id = q0;
  perform tests.eq('T76a approved', (select status from public.quotations where id = q0), 'approved');
  perform tests.eq('T76b approver recorded', (select approved_by from public.quotations where id = q0), admin_id);
  perform tests.eq('T76c case moved to approved', (select status from public.cases where id = c2), 'approved');
  perform tests.eq('T76d snapshot final amount', (snap->>'total')::numeric, 247.50::numeric);
  perform tests.eq('T76e snapshot keeps product, sku, manufacturer',
    (snap->'items'->0->'product'->>'name') || '|' || (snap->'items'->0->'product'->>'sku') || '|' || (snap->'items'->0->'product'->>'manufacturer'),
    'TEST PRODUCT A|TST-001|Ottobock');
  perform tests.eq('T76f snapshot keeps discount and tax', (snap->>'discount_percent') || '/' || (snap->>'tax_rate'), '10.00/10.00');
  perform tests.eq('T76g approve stored an approved revision', (select count(*) from public.quotation_revisions where quotation_id = q0 and kind = 'approved')::int, 1);
  perform tests.expect_error('T76h approved quotation is immutable',
    format('update public.quotations set notes = %L where id = %L', 'x', q0), '23514');
  perform tests.expect_error('T76i approved quotation items are locked',
    format('delete from public.quotation_items where quotation_id = %L', q0), '23514');
  perform tests.expect_error('T76j approved quotation cannot be revised',
    format('select public.revise_quotation(%L)', q0), '23514');
  perform tests.logout();

  -- catalog changes after approval do not touch history
  perform tests.login(mgmt);
  update public.products set name = 'RENAMED PRODUCT' where id = prod;
  insert into public.product_price_history (product_id, price, currency) values (prod, 150.00, 'USD');
  perform tests.logout();
  perform tests.eq('T77a approved snapshot unchanged after rename and new price',
    (select (snapshot->'items'->0->'product'->>'name') || '@' || (snapshot->'items'->0->>'unit_price') from public.quotations where id = q0),
    'TEST PRODUCT A@100.00');
  perform tests.eq('T77b ...and the quotation total', (select (snapshot->>'total')::numeric from public.quotations where id = q0), 247.50::numeric);

  -- ---- reject / revise / supersede on a second case ----
  perform tests.login(mgmt);
  insert into public.cases (patient_id, case_type) values (p1, 'prosthetic') returning id into c3;
  perform public.advance_case(c3, 'product_selection');
  insert into public.quotations (case_id, currency, tax_rate) values (c3, 'USD', 5) returning id into q2;
  insert into public.quotation_items (quotation_id, item_type, product_id, description, quantity) values (q2, 'product', prod, 'x', 1);
  perform tests.eq('T78a new quotation uses the latest base price (150)', (select unit_price from public.quotation_items where quotation_id = q2), 150.00);
  perform public.submit_quotation(q2);
  perform tests.logout();
  perform tests.login(admin_id);
  perform public.reject_quotation(q2, 'price too high');
  perform tests.eq('T78b rejected with reason', (select rejection_reason from public.quotations where id = q2), 'price too high');
  perform tests.logout();
  perform tests.login(mgmt);
  insert into public.product_price_history (product_id, price, currency) values (prod, 175.00, 'USD');
  select public.revise_quotation(q2) into q3;
  perform tests.eq('T78c revision number increments', (select revision from public.quotations where id = q3), 2);
  perform tests.eq('T78d revised items are re-priced to the current base price', (select unit_price from public.quotation_items where quotation_id = q3), 175.00);
  perform tests.eq('T78e rejected quotation stays as history', (select status from public.quotations where id = q2), 'rejected');
  insert into public.quotations (case_id, currency, tax_rate) values (c3, 'USD', 5) returning id into q4;
  insert into public.quotation_items (quotation_id, item_type, description, quantity, unit_price) values (q4, 'service', 'Other', 1, 10);
  perform public.submit_quotation(q3);
  perform tests.logout();
  perform tests.login(admin_id);
  perform public.approve_quotation(q3);
  perform tests.eq('T78f other open quotations of the case are superseded', (select status from public.quotations where id = q4), 'superseded');
  perform tests.eq('T78g case approved', (select status from public.cases where id = c3), 'approved');
  perform tests.eq('T78h snapshot has the re-priced amount (175 + 5% tax = 183.75)', (select (snapshot->>'total')::numeric from public.quotations where id = q3), 183.75::numeric);
  perform tests.expect_error('T78i only one approved quotation per case', format('update public.quotations set status = %L where id = %L', 'approved', q4), '42501');
  perform tests.logout();

  -- ---- visibility ----
  foreach n in array array[1] loop
    perform tests.login(tech);
    perform tests.eq('T79a technician sees no quotations', (select count(*) from public.quotations)::int, 0);
    perform tests.eq('T79b technician sees no items', (select count(*) from public.quotation_items)::int, 0);
    perform tests.eq('T79c technician sees no revisions', (select count(*) from public.quotation_revisions)::int, 0);
    perform tests.logout();
    perform tests.login(doc);
    perform tests.eq('T79d doctor sees no quotations', (select count(*) from public.quotations)::int, 0);
    perform tests.logout();
    perform tests.login(pat1);
    perform tests.eq('T79e patient sees no quotations (not enabled)', (select count(*) from public.quotations)::int, 0);
    perform tests.logout();
    perform tests.login(pat2);
    perform tests.eq('T79f other patient sees no quotations', (select count(*) from public.quotations)::int, 0);
    perform tests.logout();
  end loop;
  perform tests.anon();
  perform tests.expect_error('T79g anon denied quotations', 'select * from public.quotations', '42501');
  perform tests.logout();
  perform tests.login(mgmt);
  perform tests.eq('T79h management sees all quotations', (select count(*) from public.quotations)::int, 4);
  perform tests.logout();

  select count(*) into n from public.audit_logs where entity_type in ('quotations','quotation_items','products','product_price_history');
  perform tests.eq('T7A catalog and quotation operations audited', n >= 20, true);
end $$;
select 'PHASE 4 DB TESTS PASSED' as result;
