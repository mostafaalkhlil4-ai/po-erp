-- =====================================================================
-- Migration 0011: Inventory and procurement (Phase 6, D-028)
-- Stock is derived from an append-only movement ledger and can never go
-- negative. Purchase orders move draft -> ordered -> received/cancelled only
-- through functions; receiving writes receipt movements. Unit costs are
-- visible only to procurement/inventory staff. No items or suppliers seeded.
-- =====================================================================
create table public.suppliers (
  id         uuid primary key default gen_random_uuid(),
  name       text not null check (length(btrim(name)) between 1 and 200),
  contact    text check (contact is null or length(contact) <= 500),
  is_active  boolean not null default true,
  created_by uuid references public.profiles (id),
  created_at timestamptz not null default now()
);
create unique index suppliers_name_uq on public.suppliers (lower(btrim(name)));
create trigger suppliers_created_by before insert on public.suppliers for each row execute function public.set_created_by();
create trigger suppliers_audit after insert or update on public.suppliers for each row execute function public.audit_row_change();

create table public.inventory_items (
  id         uuid primary key default gen_random_uuid(),
  name       text not null check (length(btrim(name)) between 1 and 200),
  sku        text not null check (length(btrim(sku)) between 1 and 100),
  unit       text not null check (length(btrim(unit)) between 1 and 30),
  min_stock  numeric(12,2) not null default 0 check (min_stock >= 0),
  is_active  boolean not null default true,
  created_by uuid references public.profiles (id),
  created_at timestamptz not null default now()
);
create unique index inventory_items_sku_uq on public.inventory_items (lower(btrim(sku)));
create trigger inventory_items_created_by before insert on public.inventory_items for each row execute function public.set_created_by();
create trigger inventory_items_audit after insert or update on public.inventory_items for each row execute function public.audit_row_change();

create table public.purchase_orders (
  id          uuid primary key default gen_random_uuid(),
  po_no       bigint generated always as identity unique,
  supplier_id uuid not null references public.suppliers (id) on delete restrict,
  status      text not null default 'draft' check (status in ('draft','ordered','received','cancelled')),
  currency    text not null check (currency ~ '^[A-Z]{3}$'),
  notes       text check (notes is null or length(notes) <= 1000),
  ordered_at  timestamptz,
  received_at timestamptz,
  created_by  uuid references public.profiles (id),
  created_at  timestamptz not null default now()
);
create trigger purchase_orders_created_by before insert on public.purchase_orders for each row execute function public.set_created_by();
create trigger purchase_orders_audit after insert or update on public.purchase_orders for each row execute function public.audit_row_change();

create table public.purchase_order_items (
  id        uuid primary key default gen_random_uuid(),
  seq       bigint generated always as identity,
  po_id     uuid not null references public.purchase_orders (id) on delete restrict,
  item_id   uuid not null references public.inventory_items (id) on delete restrict,
  quantity  numeric(12,2) not null check (quantity > 0),
  unit_cost numeric(14,2) not null check (unit_cost >= 0),
  unique (po_id, item_id)
);

create table public.stock_movements (
  id          bigint generated always as identity primary key,
  item_id     uuid not null references public.inventory_items (id) on delete restrict,
  kind        text not null check (kind in ('receipt','issue','adjust_in','adjust_out')),
  quantity    numeric(12,2) not null check (quantity > 0),
  case_id     uuid references public.cases (id) on delete restrict,
  po_id       uuid references public.purchase_orders (id) on delete restrict,
  notes       text check (notes is null or length(notes) <= 1000),
  created_by  uuid references public.profiles (id),
  created_at  timestamptz not null default now(),
  check (kind <> 'issue' or case_id is not null),                         -- consumption is always tied to a case
  check (kind not in ('adjust_in','adjust_out') or length(btrim(coalesce(notes,''))) > 0)
);
create index stock_movements_item_idx on public.stock_movements (item_id);
create trigger stock_movements_immutable before update or delete on public.stock_movements
  for each row execute function public.audit_logs_immutable();
create trigger stock_movements_audit after insert on public.stock_movements
  for each row execute function public.audit_row_change();

create function public.on_hand(p_item uuid) returns numeric
language sql stable security definer set search_path = '' as $$
  select coalesce(sum(case when kind in ('receipt','adjust_in') then quantity else -quantity end), 0)
    from public.stock_movements where item_id = p_item
$$;
revoke all on function public.on_hand(uuid) from public, anon, authenticated;

create function public.stock_movements_before_insert() returns trigger
language plpgsql security definer set search_path = '' as $$
declare it public.inventory_items; v_have numeric;
begin
  select * into it from public.inventory_items where id = new.item_id for update;   -- serialises stock changes per item
  if it.id is null then raise exception 'item not found' using errcode = '23503'; end if;
  if not it.is_active then raise exception 'item is inactive' using errcode = '23514'; end if;
  if new.kind in ('issue','adjust_out') then
    v_have := public.on_hand(new.item_id);
    if v_have < new.quantity then
      raise exception 'insufficient stock (% available)', v_have using errcode = '23514';
    end if;
  end if;
  if new.kind = 'issue' and not public.case_is_open(new.case_id) then
    raise exception 'case is closed or cancelled' using errcode = '23514';
  end if;
  new.created_by := auth.uid();
  return new;
end $$;
create trigger stock_movements_bi before insert on public.stock_movements
  for each row execute function public.stock_movements_before_insert();

create function public.stock_levels() returns table (item_id uuid, on_hand numeric)
language sql stable security definer set search_path = '' as $$
  select i.id, public.on_hand(i.id) from public.inventory_items i
   where public.has_permission('inventory.manage') or public.has_permission('production.work')
$$;

-- ---------- purchase order rules ------------------------------------------
create function public.po_items_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_po uuid := coalesce(new.po_id, old.po_id);
begin
  if not exists (select 1 from public.purchase_orders where id = v_po and status = 'draft') then
    raise exception 'purchase order items can only change while the order is a draft' using errcode = '23514';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  if tg_op = 'UPDATE' and new.po_id <> old.po_id then raise exception 'po_id is immutable' using errcode = '23514'; end if;
  return new;
end $$;
create trigger po_items_guard_t before insert or update or delete on public.purchase_order_items
  for each row execute function public.po_items_guard();
create trigger po_items_audit after insert or update or delete on public.purchase_order_items
  for each row execute function public.audit_row_change();

create function public.po_header_guard() returns trigger
language plpgsql as $$
begin
  if new.supplier_id <> old.supplier_id or new.currency <> old.currency or new.po_no <> old.po_no then
    raise exception 'supplier and currency are fixed after creation' using errcode = '23514';
  end if;
  return new;
end $$;
create trigger po_header_guard_t before update on public.purchase_orders
  for each row execute function public.po_header_guard();

create function public.po_set_status(p_po uuid, p_to text) returns void
language plpgsql security definer set search_path = '' as $$
declare po public.purchase_orders; r record;
begin
  if auth.uid() is null then raise exception 'not allowed' using errcode = '42501'; end if;
  select * into po from public.purchase_orders where id = p_po for update;
  if po.id is null then raise exception 'purchase order not found' using errcode = 'P0002'; end if;
  if p_to = 'ordered' then
    if not public.has_permission('procurement.manage') then raise exception 'not allowed' using errcode = '42501'; end if;
    if po.status <> 'draft' then raise exception 'only a draft can be ordered' using errcode = '23514'; end if;
    if not exists (select 1 from public.purchase_order_items where po_id = po.id) then
      raise exception 'an order needs at least one item' using errcode = '23514';
    end if;
    if not exists (select 1 from public.suppliers where id = po.supplier_id and is_active) then
      raise exception 'supplier is inactive' using errcode = '23514';
    end if;
    update public.purchase_orders set status = 'ordered', ordered_at = now() where id = po.id;
  elsif p_to = 'cancelled' then
    if not public.has_permission('procurement.manage') then raise exception 'not allowed' using errcode = '42501'; end if;
    if po.status not in ('draft','ordered') then raise exception 'order cannot be cancelled' using errcode = '23514'; end if;
    update public.purchase_orders set status = 'cancelled' where id = po.id;
  elsif p_to = 'received' then
    if not public.has_permission('inventory.manage') then raise exception 'not allowed' using errcode = '42501'; end if;
    if po.status <> 'ordered' then raise exception 'only an ordered purchase order can be received' using errcode = '23514'; end if;
    for r in select item_id, quantity from public.purchase_order_items where po_id = po.id order by seq loop
      insert into public.stock_movements (item_id, kind, quantity, po_id, notes) values (r.item_id, 'receipt', r.quantity, po.id, 'PO ' || po.po_no);
    end loop;
    update public.purchase_orders set status = 'received', received_at = now() where id = po.id;
  else
    raise exception 'invalid status' using errcode = '23514';
  end if;
end $$;
revoke all on function public.po_set_status(uuid, text) from public, anon;
grant execute on function public.po_set_status(uuid, text) to authenticated;
revoke all on function public.stock_levels() from public, anon;
grant execute on function public.stock_levels() to authenticated;

-- ---------- privileges + RLS -----------------------------------------------
alter table public.suppliers            enable row level security;
alter table public.inventory_items      enable row level security;
alter table public.purchase_orders      enable row level security;
alter table public.purchase_order_items enable row level security;
alter table public.stock_movements      enable row level security;
alter table public.suppliers            force row level security;
alter table public.inventory_items      force row level security;
alter table public.purchase_orders      force row level security;
alter table public.purchase_order_items force row level security;
alter table public.stock_movements      force row level security;
revoke all on public.suppliers, public.inventory_items, public.purchase_orders, public.purchase_order_items, public.stock_movements from anon, authenticated;
grant select, insert on public.suppliers, public.inventory_items, public.purchase_orders, public.stock_movements to authenticated;
grant select, insert, delete on public.purchase_order_items to authenticated;
grant update (quantity, unit_cost) on public.purchase_order_items to authenticated;
grant update (name, contact, is_active) on public.suppliers to authenticated;
grant update (name, unit, min_stock, is_active) on public.inventory_items to authenticated;
grant update (notes) on public.purchase_orders to authenticated;

create policy sup_select on public.suppliers for select to authenticated using (public.has_permission('procurement.manage'));
create policy sup_insert on public.suppliers for insert to authenticated with check (public.has_permission('procurement.manage'));
create policy sup_update on public.suppliers for update to authenticated using (public.has_permission('procurement.manage')) with check (public.has_permission('procurement.manage'));
create policy inv_item_select on public.inventory_items for select to authenticated
  using (public.has_permission('inventory.manage') or public.has_permission('procurement.manage') or public.has_permission('production.work'));
create policy inv_item_insert on public.inventory_items for insert to authenticated with check (public.has_permission('inventory.manage'));
create policy inv_item_update on public.inventory_items for update to authenticated using (public.has_permission('inventory.manage')) with check (public.has_permission('inventory.manage'));
create policy po_select on public.purchase_orders for select to authenticated
  using (public.has_permission('procurement.manage') or public.has_permission('inventory.manage'));
create policy po_insert on public.purchase_orders for insert to authenticated with check (public.has_permission('procurement.manage') and status = 'draft');
create policy po_update on public.purchase_orders for update to authenticated using (public.has_permission('procurement.manage')) with check (public.has_permission('procurement.manage'));
create policy poi_select on public.purchase_order_items for select to authenticated
  using (public.has_permission('procurement.manage') or public.has_permission('inventory.manage'));
create policy poi_write on public.purchase_order_items for all to authenticated
  using (public.has_permission('procurement.manage')) with check (public.has_permission('procurement.manage'));
-- movements: inventory staff see/write all; an assigned technician may ISSUE material to an assigned case
create policy sm_select on public.stock_movements for select to authenticated
  using (public.has_permission('inventory.manage') or (case_id is not null and public.is_assigned_tech(case_id)));
create policy sm_insert on public.stock_movements for insert to authenticated
  with check (public.has_permission('inventory.manage')
              or (kind = 'issue' and public.is_assigned_tech(case_id) and public.has_permission('production.work')));
