-- Phase 6 inventory and procurement (D-028). Synthetic items only.
do $$
declare
  admin_id uuid := '00000000-0000-0000-0000-0000000000a1';
  mgmt uuid := '00000000-0000-0000-0000-0000000000a2';
  tech uuid := '00000000-0000-0000-0000-0000000000a3';
  doc  uuid := '00000000-0000-0000-0000-0000000000a4';
  pat1 uuid := '00000000-0000-0000-0000-0000000000a5';
  sup uuid; it uuid; it2 uuid; po uuid; po2 uuid; cx uuid; c_other uuid; lv numeric;
begin
  perform tests.eq('T100a no items or suppliers seeded', (select count(*) from public.inventory_items)::int + (select count(*) from public.suppliers)::int, 0);
  select v into cx from tests.p5 where k = 'case';      -- case assigned to the technician (test 08), now in fitting
  select id into c_other from public.cases where id <> cx limit 1;

  perform tests.login(tech);
  perform tests.expect_error('T100b technician cannot create items', 'insert into public.inventory_items (name, sku, unit) values (''x'',''x'',''pc'')', '42501');
  perform tests.expect_error('T100c technician cannot create suppliers', 'insert into public.suppliers (name) values (''x'')', '42501');
  perform tests.logout();
  perform tests.login(doc);
  perform tests.eq('T100d doctor sees no inventory', (select count(*) from public.inventory_items)::int, 0);
  perform tests.logout();
  perform tests.login(pat1);
  perform tests.eq('T100e patient sees no stock movements', (select count(*) from public.stock_movements)::int, 0);
  perform tests.logout();
  perform tests.anon();
  perform tests.expect_error('T100f anon denied inventory', 'select * from public.inventory_items', '42501');
  perform tests.logout();

  perform tests.login(mgmt);
  insert into public.suppliers (name, contact) values ('Test Supplier', 'n/a') returning id into sup;
  perform tests.expect_error('T101a duplicate supplier name (case-insensitive) rejected', 'insert into public.suppliers (name) values (''  test supplier '')', '23505');
  insert into public.inventory_items (name, sku, unit, min_stock) values ('Test Liner Material', 'MAT-1', 'pc', 5) returning id into it;
  insert into public.inventory_items (name, sku, unit) values ('Test Screws', 'MAT-2', 'box') returning id into it2;
  perform tests.expect_error('T101b duplicate sku rejected', 'insert into public.inventory_items (name, sku, unit) values (''y'', '' mat-1 '', ''pc'')', '23505');
  perform tests.expect_error('T101c issue without stock rejected', format('insert into public.stock_movements (item_id, kind, quantity, case_id) values (%L, %L, 1, %L)', it, 'issue', cx), '23514');
  perform tests.expect_error('T101d issue needs a case', format('insert into public.stock_movements (item_id, kind, quantity) values (%L, %L, 1)', it, 'issue'), '23514');
  perform tests.expect_error('T101e adjustment needs notes', format('insert into public.stock_movements (item_id, kind, quantity) values (%L, %L, 1)', it, 'adjust_in'), '23514');
  perform tests.expect_error('T101f zero quantity rejected', format('insert into public.stock_movements (item_id, kind, quantity, notes) values (%L, %L, 0, %L)', it, 'adjust_in', 'x'), '23514');
  insert into public.stock_movements (item_id, kind, quantity, notes) values (it, 'adjust_in', 10, 'opening count');
  select on_hand into lv from public.stock_levels() where item_id = it;
  perform tests.eq('T101g stock level after adjustment', lv, 10::numeric);
  perform tests.expect_error('T101h cannot issue more than on hand', format('insert into public.stock_movements (item_id, kind, quantity, case_id) values (%L, %L, 10.01, %L)', it, 'issue', cx), '23514');
  perform tests.expect_error('T101i ledger is append-only (update)', 'update public.stock_movements set quantity = 1', '42501');
  perform tests.expect_error('T101j ledger is append-only (delete)', 'delete from public.stock_movements', '42501');
  perform tests.logout();
  perform tests.expect_error('T101k ledger immutable even for superuser', 'update public.stock_movements set quantity = 1', 'P0001');

  perform tests.login(tech);
  perform tests.eq('T102a technician sees items and stock levels', (select count(*) from public.inventory_items)::int, 2);
  insert into public.stock_movements (item_id, kind, quantity, case_id) values (it, 'issue', 4, cx);
  perform tests.eq('T102b technician issued material to the assigned case (creator set)', (select (created_by = tech)::text from public.stock_movements where kind = 'issue'), 'true');
  perform tests.expect_error('T102c technician cannot issue to an unassigned case', format('insert into public.stock_movements (item_id, kind, quantity, case_id) values (%L, %L, 1, %L)', it, 'issue', c_other), '42501');
  perform tests.expect_error('T102d technician cannot receive stock', format('insert into public.stock_movements (item_id, kind, quantity, notes) values (%L, %L, 1, %L)', it, 'receipt', 'x'), '42501');
  perform tests.expect_error('T102e technician cannot adjust stock', format('insert into public.stock_movements (item_id, kind, quantity, notes) values (%L, %L, 1, %L)', it, 'adjust_in', 'x'), '42501');
  perform tests.eq('T102f technician sees only movements of assigned cases', (select count(*) from public.stock_movements)::int, 1);
  perform tests.eq('T102g technician sees no purchase orders', (select count(*) from public.purchase_orders)::int, 0);
  perform tests.logout();

  perform tests.login(mgmt);
  select on_hand into lv from public.stock_levels() where item_id = it;
  perform tests.eq('T102h level after issue', lv, 6::numeric);
  insert into public.purchase_orders (supplier_id, currency) values (sup, 'USD') returning id into po;
  perform tests.expect_error('T103a cannot create a PO already ordered', format('insert into public.purchase_orders (supplier_id, currency, status) values (%L, %L, %L)', sup, 'USD', 'ordered'), '42501');
  perform tests.expect_error('T103b empty order cannot be ordered', format('select public.po_set_status(%L, %L)', po, 'ordered'), '23514');
  insert into public.purchase_order_items (po_id, item_id, quantity, unit_cost) values (po, it, 20, 2.50), (po, it2, 3, 10);
  perform tests.expect_error('T103c same item twice rejected', format('insert into public.purchase_order_items (po_id, item_id, quantity, unit_cost) values (%L, %L, 1, 1)', po, it), '23505');
  perform tests.expect_error('T103d cannot receive a draft', format('select public.po_set_status(%L, %L)', po, 'received'), '23514');
  perform public.po_set_status(po, 'ordered');
  perform tests.expect_error('T103e items locked once ordered', format('insert into public.purchase_order_items (po_id, item_id, quantity, unit_cost) values (%L, %L, 1, 1)', po, it), '23514');
  perform tests.expect_error('T103f cannot order twice', format('select public.po_set_status(%L, %L)', po, 'ordered'), '23514');
  perform tests.expect_error('T103g supplier fixed after creation', format('update public.purchase_orders set supplier_id = (select id from public.suppliers limit 1), currency = %L where id = %L', 'EUR', po), '42501');
  perform public.po_set_status(po, 'received');
  select on_hand into lv from public.stock_levels() where item_id = it;
  perform tests.eq('T104a receiving added stock (6 + 20)', lv, 26::numeric);
  select on_hand into lv from public.stock_levels() where item_id = it2;
  perform tests.eq('T104b second item received', lv, 3::numeric);
  perform tests.eq('T104c PO is received with timestamp', (select status || '/' || (received_at is not null)::text from public.purchase_orders where id = po), 'received/true');
  perform tests.expect_error('T104d cannot receive twice', format('select public.po_set_status(%L, %L)', po, 'received'), '23514');
  perform tests.expect_error('T104e cannot cancel a received order', format('select public.po_set_status(%L, %L)', po, 'cancelled'), '23514');
  insert into public.purchase_orders (supplier_id, currency) values (sup, 'USD') returning id into po2;
  perform public.po_set_status(po2, 'cancelled');
  perform tests.eq('T104f draft can be cancelled', (select status from public.purchase_orders where id = po2), 'cancelled');
  update public.inventory_items set is_active = false where id = it2;
  perform tests.expect_error('T104g inactive item cannot move', format('insert into public.stock_movements (item_id, kind, quantity, notes) values (%L, %L, 1, %L)', it2, 'adjust_in', 'x'), '23514');
  perform tests.logout();

  perform tests.login(tech);
  perform tests.expect_error('T105a technician cannot order or receive', format('select public.po_set_status(%L, %L)', po, 'received'), '42501');
  perform tests.logout();
  perform tests.eq('T105b inventory operations audited', (select count(*) from public.audit_logs where entity_type in ('stock_movements','purchase_orders','inventory_items','suppliers'))::int >= 10, true);
end $$;
select 'PHASE 6 DB TESTS PASSED' as result;
