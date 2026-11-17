-- =====================================================================
-- Migration 0008: catalog and quotations (Phase 4).
-- * Manufacturers: ONLY Össur, Ottobock, PROTEOR (D-002). No products and no
--   prices are seeded: they must come from verified owner-supplied data (D-023).
-- * Prices live in an append-only history readable only by catalog/quotation
--   staff. Product item prices are fetched automatically; clients cannot set them.
-- * Approval is done by approve_quotation() only: it freezes an immutable JSON
--   snapshot (product, price, additions, discount, tax, final amount) (D-004).
-- * Assumptions (D-025): currency and tax rate are chosen per quotation (no
--   defaults); discounts need `quotations.discount`, approval needs
--   `quotations.approve` (both admin by default; admin can delegate via
--   role_permissions).
-- =====================================================================

insert into public.permissions (code, description) values
  ('quotations.discount', 'Apply discounts to quotations'),
  ('quotations.approve',  'Approve or reject submitted quotations');
insert into public.role_permissions (role, permission_code) values
  ('admin', 'quotations.discount'), ('admin', 'quotations.approve');

-- ---------- catalog ----------------------------------------------------
create table public.manufacturers (
  id   uuid primary key default gen_random_uuid(),
  name text not null unique
);
insert into public.manufacturers (name) values ('Össur'), ('Ottobock'), ('PROTEOR');

create table public.product_categories (
  id         uuid primary key default gen_random_uuid(),
  name       text not null check (length(btrim(name)) between 1 and 200),
  created_by uuid references public.profiles (id),
  created_at timestamptz not null default now()
);
create unique index product_categories_name_uq on public.product_categories (lower(btrim(name)));
create trigger product_categories_created_by before insert on public.product_categories
  for each row execute function public.set_created_by();

create table public.products (
  id              uuid primary key default gen_random_uuid(),
  manufacturer_id uuid not null references public.manufacturers (id) on delete restrict,
  category_id     uuid references public.product_categories (id) on delete restrict,
  name            text not null check (length(btrim(name)) between 1 and 300),
  sku             text not null check (length(btrim(sku)) between 1 and 100),   -- manufacturer reference, supplied by the owner
  description     text,
  is_active       boolean not null default true,
  created_by      uuid references public.profiles (id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (manufacturer_id, sku)
);
create trigger products_updated before update on public.products for each row execute function public.set_updated_at();
create trigger products_created_by before insert on public.products for each row execute function public.set_created_by();

create table public.product_price_history (
  id         bigint generated always as identity primary key,
  product_id uuid not null references public.products (id) on delete restrict,
  price      numeric(14,2) not null check (price >= 0),
  currency   text not null check (currency ~ '^[A-Z]{3}$'),
  valid_from timestamptz not null default now(),
  created_by uuid references public.profiles (id),
  created_at timestamptz not null default now()
);
create index price_history_lookup on public.product_price_history (product_id, valid_from desc, id desc);
create trigger price_history_created_by before insert on public.product_price_history
  for each row execute function public.set_created_by();
create trigger price_history_immutable before update or delete on public.product_price_history
  for each row execute function public.audit_logs_immutable();

-- ---------- quotations ---------------------------------------------------
create table public.quotations (
  id               uuid primary key default gen_random_uuid(),
  quotation_no     bigint generated always as identity unique,
  case_id          uuid not null references public.cases (id) on delete restrict,
  revision         int not null default 1 check (revision >= 1),
  status           text not null default 'draft'
                   check (status in ('draft','submitted','approved','rejected','superseded')),
  currency         text not null check (currency ~ '^[A-Z]{3}$'),
  tax_rate         numeric(5,2) not null check (tax_rate between 0 and 100),
  discount_percent numeric(5,2) not null default 0 check (discount_percent between 0 and 100),
  notes            text,
  rejection_reason text,
  snapshot         jsonb,
  approved_at      timestamptz,
  approved_by      uuid references public.profiles (id),
  created_by       uuid references public.profiles (id),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  check ((status = 'approved') = (snapshot is not null))
);
create index quotations_case_idx on public.quotations (case_id);
create unique index quotations_one_approved_per_case on public.quotations (case_id) where status = 'approved';
create trigger quotations_updated before update on public.quotations for each row execute function public.set_updated_at();
create trigger quotations_created_by before insert on public.quotations for each row execute function public.set_created_by();

create table public.quotation_items (
  id           uuid primary key default gen_random_uuid(),
  quotation_id uuid not null references public.quotations (id) on delete restrict,
  item_type    text not null check (item_type in ('product','material','service')),
  product_id   uuid references public.products (id) on delete restrict,
  description  text not null check (length(btrim(description)) between 1 and 500),
  quantity     numeric(10,2) not null check (quantity > 0),
  unit_price   numeric(14,2) not null check (unit_price >= 0),
  line_total   numeric(14,2) generated always as (round(quantity * unit_price, 2)) stored,
  created_at   timestamptz not null default now(),
  check ((item_type = 'product') = (product_id is not null))
);
create index quotation_items_q_idx on public.quotation_items (quotation_id);

create table public.quotation_revisions (
  id           bigint generated always as identity primary key,
  quotation_id uuid not null references public.quotations (id) on delete restrict,
  revision     int not null,
  kind         text not null check (kind in ('submitted','approved','rejected')),
  snapshot     jsonb not null,
  created_by   uuid,
  created_at   timestamptz not null default now()
);
create index quotation_revisions_q_idx on public.quotation_revisions (quotation_id);
create trigger quotation_revisions_immutable before update or delete on public.quotation_revisions
  for each row execute function public.audit_logs_immutable();

-- ---------- helpers ------------------------------------------------------
create function public.can_manage_quotations() returns boolean
language sql stable security definer set search_path = '' as $$
  select public.has_permission('quotations.manage')
$$;

create function public.case_accepts_quotation(p_case uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.cases where id = p_case and status in ('product_selection', 'quotation'))
$$;

-- totals: subtotal, discount, tax, total (numeric rounding: half away from zero)
create function public.quotation_totals(p_q uuid)
returns table (subtotal numeric, discount_amount numeric, tax_amount numeric, total numeric)
language sql stable set search_path = '' as $$
  with s as (
    select coalesce((select sum(i.line_total) from public.quotation_items i where i.quotation_id = p_q), 0) as sub,
           q.discount_percent as dp, q.tax_rate as tr
    from public.quotations q where q.id = p_q
  ), d as (
    select sub, round(sub * dp / 100, 2) as disc, tr from s
  ), t as (
    select sub, disc, round((sub - disc) * tr / 100, 2) as tax from d
  )
  select sub::numeric, disc::numeric, tax::numeric, (sub - disc + tax)::numeric from t
$$;

create function public.quotation_snapshot(p_q uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_q public.quotations; v_items jsonb; v_t record;
begin
  select * into v_q from public.quotations where id = p_q;
  select coalesce(jsonb_agg(jsonb_build_object(
           'item_type', i.item_type, 'description', i.description,
           'quantity', i.quantity, 'unit_price', i.unit_price, 'line_total', i.line_total,
           'product', case when i.product_id is null then null else jsonb_build_object(
               'id', p.id, 'name', p.name, 'sku', p.sku, 'manufacturer', m.name) end
         ) order by i.created_at, i.id), '[]'::jsonb)
    into v_items
    from public.quotation_items i
    left join public.products p on p.id = i.product_id
    left join public.manufacturers m on m.id = p.manufacturer_id
   where i.quotation_id = p_q;
  select * into v_t from public.quotation_totals(p_q);
  return jsonb_build_object(
    'quotation_no', v_q.quotation_no, 'revision', v_q.revision, 'case_id', v_q.case_id,
    'currency', v_q.currency, 'tax_rate', v_q.tax_rate, 'discount_percent', v_q.discount_percent,
    'items', v_items,
    'subtotal', v_t.subtotal, 'discount_amount', v_t.discount_amount,
    'tax_amount', v_t.tax_amount, 'total', v_t.total,
    'captured_at', now());
end $$;
revoke all on function public.quotation_snapshot(uuid) from public, anon, authenticated;

-- ---------- triggers -------------------------------------------------------
create function public.quotations_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    if new.discount_percent <> 0 and auth.uid() is not null and not public.has_permission('quotations.discount') then
      raise exception 'discount requires the quotations.discount permission' using errcode = '42501';
    end if;
    return new;
  end if;
  if old.status = 'approved' then
    raise exception 'approved quotation is immutable' using errcode = '23514';
  end if;
  if new.discount_percent is distinct from old.discount_percent
     and auth.uid() is not null and not public.has_permission('quotations.discount') then
    raise exception 'discount requires the quotations.discount permission' using errcode = '42501';
  end if;
  if old.status <> 'draft' and (new.currency is distinct from old.currency
        or new.tax_rate is distinct from old.tax_rate
        or new.discount_percent is distinct from old.discount_percent
        or new.notes is distinct from old.notes
        or new.case_id is distinct from old.case_id) then
    raise exception 'only draft quotations can be edited' using errcode = '23514';
  end if;
  if new.currency is distinct from old.currency
     and exists (select 1 from public.quotation_items where quotation_id = old.id) then
    raise exception 'currency cannot change once items exist' using errcode = '23514';
  end if;
  return new;
end $$;
create trigger quotations_guard_t before insert or update on public.quotations
  for each row execute function public.quotations_guard();

create function public.quotation_items_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_qid uuid := case when tg_op = 'DELETE' then old.quotation_id else new.quotation_id end;
  v_q public.quotations; v_p public.products; v_price numeric; v_cur text;
begin
  select * into v_q from public.quotations where id = v_qid;
  if v_q.status <> 'draft' then
    raise exception 'quotation is not a draft' using errcode = '23514';
  end if;
  if tg_op = 'DELETE' then return old; end if;

  if tg_op = 'UPDATE' and (new.item_type <> old.item_type or new.product_id is distinct from old.product_id
                           or new.quotation_id <> old.quotation_id or new.unit_price is distinct from old.unit_price) then
    raise exception 'only quantity and description can be edited' using errcode = '23514';
  end if;

  if tg_op = 'INSERT' and new.item_type = 'product' then
    select * into v_p from public.products where id = new.product_id;
    if v_p.id is null or not v_p.is_active then
      raise exception 'product is missing or inactive' using errcode = '23514';
    end if;
    select price, currency into v_price, v_cur from public.product_price_history
     where product_id = new.product_id and valid_from <= now()
     order by valid_from desc, id desc limit 1;
    if v_price is null then
      raise exception 'product has no base price' using errcode = '23514';
    end if;
    if v_cur <> v_q.currency then
      raise exception 'product price currency % differs from quotation currency %', v_cur, v_q.currency using errcode = '23514';
    end if;
    new.unit_price := v_price;                 -- client-supplied price is ignored
    new.description := v_p.name;
  end if;
  return new;
end $$;
create trigger quotation_items_guard_t before insert or update or delete on public.quotation_items
  for each row execute function public.quotation_items_guard();

create trigger manufacturers_audit after insert or update on public.manufacturers for each row execute function public.audit_row_change();
create trigger products_audit after insert or update on public.products for each row execute function public.audit_row_change();
create trigger price_history_audit after insert on public.product_price_history for each row execute function public.audit_row_change();
create trigger quotations_audit after insert or update on public.quotations for each row execute function public.audit_row_change();
create trigger quotation_items_audit after insert or update or delete on public.quotation_items for each row execute function public.audit_row_change();

-- ---------- workflow functions -------------------------------------------
create function public.submit_quotation(p_q uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v public.quotations;
begin
  if auth.uid() is null or not public.has_permission('quotations.manage') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  select * into v from public.quotations where id = p_q for update;
  if v.id is null then raise exception 'not found' using errcode = 'P0002'; end if;
  if v.status <> 'draft' then raise exception 'only drafts can be submitted' using errcode = '23514'; end if;
  if not exists (select 1 from public.quotation_items where quotation_id = p_q) then
    raise exception 'quotation has no items' using errcode = '23514';
  end if;
  if not public.case_accepts_quotation(v.case_id) then
    raise exception 'case is not in a quotable stage' using errcode = '23514';
  end if;
  insert into public.quotation_revisions (quotation_id, revision, kind, snapshot, created_by)
    values (p_q, v.revision, 'submitted', public.quotation_snapshot(p_q), auth.uid());
  update public.quotations set status = 'submitted' where id = p_q;
  if exists (select 1 from public.cases where id = v.case_id and status = 'product_selection') then
    update public.cases set status = 'quotation' where id = v.case_id;
    insert into public.case_events (case_id, event_type, from_status, to_status, note, actor_id)
      values (v.case_id, 'status_change', 'product_selection', 'quotation', 'quotation #' || v.quotation_no, auth.uid());
  end if;
end $$;

create function public.reject_quotation(p_q uuid, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
declare v public.quotations;
begin
  if auth.uid() is null or not public.has_permission('quotations.approve') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  select * into v from public.quotations where id = p_q for update;
  if v.id is null then raise exception 'not found' using errcode = 'P0002'; end if;
  if v.status <> 'submitted' then raise exception 'only submitted quotations can be rejected' using errcode = '23514'; end if;
  insert into public.quotation_revisions (quotation_id, revision, kind, snapshot, created_by)
    values (p_q, v.revision, 'rejected', public.quotation_snapshot(p_q) || jsonb_build_object('reason', p_reason), auth.uid());
  update public.quotations set status = 'rejected', rejection_reason = p_reason where id = p_q;
end $$;

create function public.approve_quotation(p_q uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v public.quotations; v_snap jsonb;
begin
  if auth.uid() is null or not public.has_permission('quotations.approve') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  select * into v from public.quotations where id = p_q for update;
  if v.id is null then raise exception 'not found' using errcode = 'P0002'; end if;
  if v.status <> 'submitted' then raise exception 'only submitted quotations can be approved' using errcode = '23514'; end if;
  if not exists (select 1 from public.cases where id = v.case_id and status = 'quotation') then
    raise exception 'case is not awaiting quotation approval' using errcode = '23514';
  end if;
  v_snap := public.quotation_snapshot(p_q);
  insert into public.quotation_revisions (quotation_id, revision, kind, snapshot, created_by)
    values (p_q, v.revision, 'approved', v_snap, auth.uid());
  -- other open quotations of the same case are superseded
  update public.quotations set status = 'superseded'
   where case_id = v.case_id and id <> p_q and status in ('draft', 'submitted');
  update public.quotations set status = 'approved', snapshot = v_snap, approved_at = now(), approved_by = auth.uid()
   where id = p_q;
  update public.cases set status = 'approved' where id = v.case_id;
  insert into public.case_events (case_id, event_type, from_status, to_status, note, actor_id)
    values (v.case_id, 'status_change', 'quotation', 'approved', 'quotation #' || v.quotation_no || ' rev ' || v.revision, auth.uid());
end $$;

create function public.revise_quotation(p_q uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v public.quotations; v_new uuid; v_rev int;
begin
  if auth.uid() is null or not public.has_permission('quotations.manage') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  select * into v from public.quotations where id = p_q for update;
  if v.id is null then raise exception 'not found' using errcode = 'P0002'; end if;
  if v.status not in ('submitted', 'rejected') then
    raise exception 'only submitted or rejected quotations can be revised' using errcode = '23514';
  end if;
  if not public.case_accepts_quotation(v.case_id) then
    raise exception 'case is not in a quotable stage' using errcode = '23514';
  end if;
  select max(revision) + 1 into v_rev from public.quotations where case_id = v.case_id;
  insert into public.quotations (case_id, revision, currency, tax_rate, discount_percent, notes)
    values (v.case_id, v_rev, v.currency, v.tax_rate, v.discount_percent, v.notes)
    returning id into v_new;
  -- items are re-created, so product prices are refreshed to the current base price
  insert into public.quotation_items (quotation_id, item_type, product_id, description, quantity, unit_price)
    select v_new, item_type, product_id, description, quantity, unit_price
      from public.quotation_items where quotation_id = p_q order by created_at, id;
  if v.status = 'submitted' then
    update public.quotations set status = 'superseded' where id = p_q;
  end if;
  return v_new;
end $$;

revoke all on function public.submit_quotation(uuid), public.reject_quotation(uuid, text),
                       public.approve_quotation(uuid), public.revise_quotation(uuid) from public, anon;
grant execute on function public.submit_quotation(uuid), public.reject_quotation(uuid, text),
                          public.approve_quotation(uuid), public.revise_quotation(uuid) to authenticated;

-- advance_case: the approval step now has exactly one path (approve_quotation)
create or replace function public.advance_case(p_case uuid, p_to text, p_note text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_from text;
  v_staff boolean := public.has_permission('cases.write');
  v_tech  boolean := public.is_assigned_tech(p_case) and public.has_permission('production.work');
  v_kind  text;
begin
  if auth.uid() is null or not (v_staff or v_tech) then
    raise exception 'not allowed to change this case' using errcode = '42501';
  end if;
  select status into v_from from public.cases where id = p_case for update;
  if v_from is null then
    raise exception 'case not found' using errcode = 'P0002';
  end if;
  v_kind := case when v_staff then 'staff' else 'technician' end;
  if not exists (select 1 from public.case_transitions
                 where from_status = v_from and to_status = p_to and actor_kind = v_kind) then
    if v_staff and not exists (select 1 from public.case_transitions where from_status = v_from and to_status = p_to) then
      raise exception 'invalid transition % -> %', v_from, p_to using errcode = '23514';
    end if;
    raise exception 'transition % -> % not allowed for this user', v_from, p_to
      using errcode = case when v_staff then '23514' else '42501' end;
  end if;
  if v_from = 'quotation' and p_to = 'approved' then
    raise exception 'use approve_quotation(): approval requires an approved quotation snapshot' using errcode = '0A000';
  end if;
  update public.cases
     set status = p_to,
         closed_at = case when p_to = 'closed' then now() when v_from = 'closed' then null else closed_at end
   where id = p_case;
  insert into public.case_events (case_id, event_type, from_status, to_status, note, actor_id)
  values (p_case, 'status_change', v_from, p_to, p_note, auth.uid());
end $$;

-- ---------- privileges + RLS ----------------------------------------------
alter table public.manufacturers        enable row level security;
alter table public.product_categories   enable row level security;
alter table public.products             enable row level security;
alter table public.product_price_history enable row level security;
alter table public.quotations           enable row level security;
alter table public.quotation_items      enable row level security;
alter table public.quotation_revisions  enable row level security;
alter table public.manufacturers        force row level security;
alter table public.product_categories   force row level security;
alter table public.products             force row level security;
alter table public.product_price_history force row level security;
alter table public.quotations           force row level security;
alter table public.quotation_items      force row level security;
alter table public.quotation_revisions  force row level security;

revoke all on public.manufacturers, public.product_categories, public.products, public.product_price_history,
              public.quotations, public.quotation_items, public.quotation_revisions from anon, authenticated;
grant select on public.manufacturers, public.quotation_revisions to authenticated;   -- manufacturers: fixed list (D-002)
grant select, insert on public.product_categories, public.products, public.product_price_history, public.quotations to authenticated;
grant select, insert, delete on public.quotation_items to authenticated;
grant update (name, category_id, description, is_active) on public.products to authenticated;
grant update (currency, tax_rate, discount_percent, notes) on public.quotations to authenticated;
grant update (quantity, description) on public.quotation_items to authenticated;

create policy mf_select on public.manufacturers for select to authenticated using (public.has_permission('catalog.read'));
create policy pc_select on public.product_categories for select to authenticated using (public.has_permission('catalog.read'));
create policy pc_insert on public.product_categories for insert to authenticated with check (public.has_permission('catalog.manage'));
create policy pr_select on public.products for select to authenticated using (public.has_permission('catalog.read'));
create policy pr_insert on public.products for insert to authenticated with check (public.has_permission('catalog.manage'));
create policy pr_update on public.products for update to authenticated
  using (public.has_permission('catalog.manage')) with check (public.has_permission('catalog.manage'));
create policy ph_select on public.product_price_history for select to authenticated
  using (public.has_permission('catalog.manage') or public.has_permission('quotations.manage'));
create policy ph_insert on public.product_price_history for insert to authenticated
  with check (public.has_permission('catalog.manage'));

create policy qt_select on public.quotations for select to authenticated using (public.can_manage_quotations());
create policy qt_insert on public.quotations for insert to authenticated
  with check (public.can_manage_quotations() and status = 'draft' and snapshot is null
              and public.case_accepts_quotation(case_id));
create policy qt_update on public.quotations for update to authenticated
  using (public.can_manage_quotations()) with check (public.can_manage_quotations());
create policy qi_select on public.quotation_items for select to authenticated using (public.can_manage_quotations());
create policy qi_write on public.quotation_items for all to authenticated
  using (public.can_manage_quotations()) with check (public.can_manage_quotations());
create policy qr_select on public.quotation_revisions for select to authenticated using (public.can_manage_quotations());
