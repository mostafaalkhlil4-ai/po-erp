-- =====================================================================
-- Migration 0010: Finance (Phase 7, D-027)
-- Invoices are issued only from an approved quotation snapshot (amount and
-- currency copied, immutable). Payments and expenses are append-only.
-- Everything requires finance.manage (admin, management by default).
-- =====================================================================
create table public.invoices (
  id            uuid primary key default gen_random_uuid(),
  invoice_no    bigint generated always as identity unique,
  quotation_id  uuid not null unique references public.quotations (id) on delete restrict,
  case_id       uuid not null references public.cases (id) on delete restrict,
  patient_id    uuid not null references public.patients (id) on delete restrict,
  currency      text not null check (currency ~ '^[A-Z]{3}$'),
  amount        numeric(14,2) not null check (amount > 0),
  status        text not null default 'issued' check (status in ('issued','void')),
  void_reason   text,
  voided_at     timestamptz,
  issued_by     uuid references public.profiles (id),
  issued_at     timestamptz not null default now(),
  check ((status = 'void') = (voided_at is not null and length(btrim(coalesce(void_reason,''))) > 0))
);
create index invoices_patient_idx on public.invoices (patient_id);
create index invoices_case_idx on public.invoices (case_id);

create table public.payments (
  id         uuid primary key default gen_random_uuid(),
  invoice_id uuid not null references public.invoices (id) on delete restrict,
  amount     numeric(14,2) not null check (amount > 0),
  currency   text not null,
  method     text not null check (method in ('cash','bank_transfer','card','other')),
  reference  text check (reference is null or length(reference) <= 200),
  paid_at    timestamptz not null default now(),
  created_by uuid references public.profiles (id),
  created_at timestamptz not null default now()
);
create index payments_invoice_idx on public.payments (invoice_id);

create table public.expenses (
  id          uuid primary key default gen_random_uuid(),
  category    text not null check (length(btrim(category)) between 1 and 100),
  description text check (description is null or length(description) <= 1000),
  amount      numeric(14,2) not null check (amount > 0),
  currency    text not null check (currency ~ '^[A-Z]{3}$'),
  incurred_on date not null,
  created_by  uuid references public.profiles (id),
  created_at  timestamptz not null default now()
);

-- ---------- invoices: only through functions -------------------------------
create function public.issue_invoice(p_quotation uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare q public.quotations; v_patient uuid; v_id uuid;
begin
  if auth.uid() is null or not public.has_permission('finance.manage') then
    raise exception 'not allowed to issue invoices' using errcode = '42501';
  end if;
  select * into q from public.quotations where id = p_quotation for update;
  if q.id is null then raise exception 'quotation not found' using errcode = 'P0002'; end if;
  if q.status <> 'approved' or q.snapshot is null then
    raise exception 'invoices can only be issued from an approved quotation' using errcode = '23514';
  end if;
  select patient_id into v_patient from public.cases where id = q.case_id;
  insert into public.invoices (quotation_id, case_id, patient_id, currency, amount, issued_by)
  values (q.id, q.case_id, v_patient, q.snapshot->>'currency', (q.snapshot->>'total')::numeric, auth.uid())
  returning id into v_id;
  return v_id;
end $$;

create function public.void_invoice(p_invoice uuid, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
declare i public.invoices;
begin
  if auth.uid() is null or not public.has_permission('finance.manage') then
    raise exception 'not allowed to void invoices' using errcode = '42501';
  end if;
  select * into i from public.invoices where id = p_invoice for update;
  if i.id is null then raise exception 'invoice not found' using errcode = 'P0002'; end if;
  if i.status = 'void' then raise exception 'invoice already void' using errcode = '23514'; end if;
  if exists (select 1 from public.payments where invoice_id = i.id) then
    raise exception 'an invoice with payments cannot be voided' using errcode = '23514';
  end if;
  if length(btrim(coalesce(p_reason,''))) = 0 then
    raise exception 'a reason is required' using errcode = '23514';
  end if;
  update public.invoices set status = 'void', void_reason = btrim(p_reason), voided_at = now() where id = i.id;
end $$;

create function public.invoice_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then raise exception 'invoices cannot be deleted' using errcode = '42501'; end if;
  if old.status = 'void' then raise exception 'void invoice is immutable' using errcode = '23514'; end if;
  if new.quotation_id <> old.quotation_id or new.case_id <> old.case_id or new.patient_id <> old.patient_id
     or new.currency <> old.currency or new.amount <> old.amount or new.invoice_no <> old.invoice_no
     or new.issued_at <> old.issued_at or new.issued_by is distinct from old.issued_by then
    raise exception 'invoice figures are immutable' using errcode = '23514';
  end if;
  return new;
end $$;
create trigger invoices_guard before update or delete on public.invoices
  for each row execute function public.invoice_guard();
create trigger invoices_audit after insert or update on public.invoices
  for each row execute function public.audit_row_change();

-- ---------- payments: append-only, never above the balance ------------------
create function public.payments_before_insert() returns trigger
language plpgsql security definer set search_path = '' as $$
declare i public.invoices; v_paid numeric;
begin
  select * into i from public.invoices where id = new.invoice_id for update;   -- serialises concurrent payments
  if i.id is null then raise exception 'invoice not found' using errcode = '23503'; end if;
  if i.status <> 'issued' then raise exception 'cannot pay a void invoice' using errcode = '23514'; end if;
  select coalesce(sum(amount), 0) into v_paid from public.payments where invoice_id = i.id;
  if v_paid + new.amount > i.amount then
    raise exception 'payment exceeds the invoice balance' using errcode = '23514';
  end if;
  new.currency := i.currency;      -- cannot be chosen by the client
  new.created_by := auth.uid();
  return new;
end $$;
create trigger payments_before_insert before insert on public.payments
  for each row execute function public.payments_before_insert();
create trigger payments_immutable before update or delete on public.payments
  for each row execute function public.audit_logs_immutable();
create trigger payments_audit after insert on public.payments
  for each row execute function public.audit_row_change();

create trigger expenses_created_by before insert on public.expenses
  for each row execute function public.set_created_by();
create trigger expenses_immutable before update or delete on public.expenses
  for each row execute function public.audit_logs_immutable();
create trigger expenses_audit after insert on public.expenses
  for each row execute function public.audit_row_change();

create function public.invoice_summary(p_invoice uuid)
returns table (amount numeric, paid numeric, balance numeric)
language sql stable security definer set search_path = '' as $$
  select i.amount, coalesce(sum(p.amount), 0), i.amount - coalesce(sum(p.amount), 0)
    from public.invoices i left join public.payments p on p.invoice_id = i.id
   where i.id = p_invoice and public.has_permission('finance.manage')
   group by i.id
$$;

-- ---------- privileges + RLS -----------------------------------------------
alter table public.invoices enable row level security;
alter table public.payments enable row level security;
alter table public.expenses enable row level security;
alter table public.invoices force row level security;
alter table public.payments force row level security;
alter table public.expenses force row level security;
revoke all on public.invoices, public.payments, public.expenses from anon, authenticated;
grant select on public.invoices to authenticated;                    -- writes via issue_invoice / void_invoice
grant select, insert on public.payments, public.expenses to authenticated;
revoke all on function public.issue_invoice(uuid), public.void_invoice(uuid, text), public.invoice_summary(uuid) from public, anon;
grant execute on function public.issue_invoice(uuid), public.void_invoice(uuid, text), public.invoice_summary(uuid) to authenticated;

create policy inv_select on public.invoices for select to authenticated using (public.has_permission('finance.manage'));
create policy pay_select on public.payments for select to authenticated using (public.has_permission('finance.manage'));
create policy pay_insert on public.payments for insert to authenticated with check (public.has_permission('finance.manage'));
create policy exp_select on public.expenses for select to authenticated using (public.has_permission('finance.manage'));
create policy exp_insert on public.expenses for insert to authenticated with check (public.has_permission('finance.manage'));
