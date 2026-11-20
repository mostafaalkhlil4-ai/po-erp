-- =====================================================================
-- Migration 0012: Patient portal - own approved quotation and own invoices (D-029)
-- Exposed ONLY through functions that return a safe projection: approved
-- quotation snapshots (no internal notes, no rejection data, no drafts) and
-- issued invoices with paid/balance. Void invoices and drafts stay hidden.
-- =====================================================================
create function public.my_quotations()
returns table (quotation_id uuid, quotation_no bigint, case_id uuid, currency text, snapshot jsonb, approved_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select q.id, q.quotation_no, q.case_id, q.currency, q.snapshot, q.approved_at
    from public.quotations q
   where q.status = 'approved' and q.snapshot is not null
     and public.is_patient_self(public.case_patient(q.case_id))
   order by q.quotation_no desc
$$;

create function public.my_invoices()
returns table (invoice_id uuid, invoice_no bigint, case_id uuid, currency text, amount numeric, paid numeric, balance numeric, issued_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select i.id, i.invoice_no, i.case_id, i.currency, i.amount,
         coalesce(sum(p.amount), 0), i.amount - coalesce(sum(p.amount), 0), i.issued_at
    from public.invoices i left join public.payments p on p.invoice_id = i.id
   where i.status = 'issued' and public.is_patient_self(i.patient_id)
   group by i.id
   order by i.invoice_no desc
$$;
revoke all on function public.my_quotations(), public.my_invoices() from public, anon;
grant execute on function public.my_quotations(), public.my_invoices() to authenticated;
