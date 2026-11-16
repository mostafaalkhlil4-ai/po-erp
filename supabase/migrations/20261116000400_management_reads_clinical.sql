-- =====================================================================
-- Migration 0004 (decision D-019, approved by the owner on 2026-11-16):
-- Management may READ internal clinical records (diagnoses, notes,
-- assessments, prescriptions, reports incl. drafts) of ALL patients.
-- Management still cannot WRITE clinical data.
-- Read and write were previously coupled to one permission; split them.
-- =====================================================================
insert into public.permissions (code, description) values
  ('clinical.manage', 'Write clinical data for any patient (admin only)');
insert into public.role_permissions (role, permission_code) values
  ('admin', 'clinical.manage'),
  ('management', 'clinical.read_all');

create or replace function public.can_write_clinical(p_patient uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select public.has_permission('clinical.manage')
      or (public.has_permission('clinical.write') and public.is_doctor_of(p_patient))
$$;

drop policy rx_insert on public.prescriptions;
create policy rx_insert on public.prescriptions for insert to authenticated
  with check (public.can_write_clinical(patient_id)
              and (public.is_doctor_self(doctor_id) or public.has_permission('clinical.manage')));
