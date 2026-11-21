-- =====================================================================
-- Migration 0013: Patient billing visibility is decided manually by staff (D-029 amended)
-- Nothing is visible to the patient by default. Staff with quotations.manage
-- (for an approved quotation) or finance.manage (for an issued invoice)
-- share or withdraw it per item. Stored outside the immutable rows.
-- =====================================================================
create table public.patient_visibility (
  kind    text not null check (kind in ('quotation','invoice')),
  ref_id  uuid not null,
  visible boolean not null,
  set_by  uuid references public.profiles (id),
  set_at  timestamptz not null default now(),
  primary key (kind, ref_id)
);
create trigger patient_visibility_audit after insert or update on public.patient_visibility
  for each row execute function public.audit_row_change();

create function public.set_patient_visibility(p_kind text, p_ref uuid, p_visible boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'not allowed' using errcode = '42501'; end if;
  if p_kind = 'quotation' then
    if not public.has_permission('quotations.manage') then raise exception 'not allowed' using errcode = '42501'; end if;
    if not exists (select 1 from public.quotations where id = p_ref and status = 'approved') then
      raise exception 'only an approved quotation can be shared' using errcode = '23514';
    end if;
  elsif p_kind = 'invoice' then
    if not public.has_permission('finance.manage') then raise exception 'not allowed' using errcode = '42501'; end if;
    if not exists (select 1 from public.invoices where id = p_ref and status = 'issued') then
      raise exception 'only an issued invoice can be shared' using errcode = '23514';
    end if;
  else
    raise exception 'invalid kind' using errcode = '23514';
  end if;
  insert into public.patient_visibility (kind, ref_id, visible, set_by) values (p_kind, p_ref, p_visible, auth.uid())
  on conflict (kind, ref_id) do update set visible = excluded.visible, set_by = excluded.set_by, set_at = now();
end $$;
revoke all on function public.set_patient_visibility(text, uuid, boolean) from public, anon;
grant execute on function public.set_patient_visibility(text, uuid, boolean) to authenticated;

create function public.is_shared(p_kind text, p_ref uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select visible from public.patient_visibility where kind = p_kind and ref_id = p_ref), false)
$$;
revoke all on function public.is_shared(text, uuid) from public, anon, authenticated;

create function public.visibility_of(p_kind text) returns table (ref_id uuid, visible boolean)
language sql stable security definer set search_path = '' as $$
  select v.ref_id, v.visible from public.patient_visibility v
   where v.kind = p_kind and (public.has_permission('quotations.manage') or public.has_permission('finance.manage'))
$$;
revoke all on function public.visibility_of(text) from public, anon;
grant execute on function public.visibility_of(text) to authenticated;

create or replace function public.my_quotations()
returns table (quotation_id uuid, quotation_no bigint, case_id uuid, currency text, snapshot jsonb, approved_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select q.id, q.quotation_no, q.case_id, q.currency, q.snapshot, q.approved_at
    from public.quotations q
   where q.status = 'approved' and q.snapshot is not null
     and public.is_patient_self(public.case_patient(q.case_id))
     and public.is_shared('quotation', q.id)
   order by q.quotation_no desc
$$;

create or replace function public.my_invoices()
returns table (invoice_id uuid, invoice_no bigint, case_id uuid, currency text, amount numeric, paid numeric, balance numeric, issued_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select i.id, i.invoice_no, i.case_id, i.currency, i.amount,
         coalesce(sum(p.amount), 0), i.amount - coalesce(sum(p.amount), 0), i.issued_at
    from public.invoices i left join public.payments p on p.invoice_id = i.id
   where i.status = 'issued' and public.is_patient_self(i.patient_id) and public.is_shared('invoice', i.id)
   group by i.id
   order by i.invoice_no desc
$$;

alter table public.patient_visibility enable row level security;
alter table public.patient_visibility force row level security;
revoke all on public.patient_visibility from anon, authenticated;   -- only through the functions
