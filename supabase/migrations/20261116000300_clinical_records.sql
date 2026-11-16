-- =====================================================================
-- Migration 0003: clinical data (Phase 2)
-- INTERNAL clinical tables are readable only by admin and the doctor actively
-- linked to the patient. Patient-visible content lives ONLY in
-- shareable_reports (published). Management and technicians get no access here
-- (technical data comes with cases/assignments in Phase 3).
-- Clinical entries are append-only; corrections are new entries.
-- =====================================================================

insert into public.permissions (code, description) values
  ('clinical.read_all', 'Read all internal clinical records (admin only)');
insert into public.role_permissions (role, permission_code) values ('admin', 'clinical.read_all');

create function public.set_author() returns trigger
language plpgsql as $$
begin
  new.author_id := auth.uid();   -- cannot be spoofed by the client
  return new;
end $$;

create function public.can_read_clinical(p_patient uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select public.has_permission('clinical.read_all') or public.is_doctor_of(p_patient)
$$;

create function public.can_write_clinical(p_patient uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select public.has_permission('clinical.read_all')
      or (public.has_permission('clinical.write') and public.is_doctor_of(p_patient))
$$;

-- ---------- internal clinical tables -----------------------------------
create table public.medical_records (
  id          uuid primary key default gen_random_uuid(),
  patient_id  uuid not null references public.patients (id) on delete restrict,
  record_type text not null check (record_type in ('history', 'diagnosis', 'allergy', 'other')),
  summary     text not null check (length(btrim(summary)) between 1 and 500),
  details     text,
  author_id   uuid references public.profiles (id),
  created_at  timestamptz not null default now()
);
create table public.clinical_notes (
  id         uuid primary key default gen_random_uuid(),
  patient_id uuid not null references public.patients (id) on delete restrict,
  body       text not null check (length(btrim(body)) >= 1),
  author_id  uuid references public.profiles (id),
  created_at timestamptz not null default now()
);
create table public.assessments (
  id              uuid primary key default gen_random_uuid(),
  patient_id      uuid not null references public.patients (id) on delete restrict,
  assessment_type text not null check (assessment_type in ('clinical', 'technical')),
  findings        text not null check (length(btrim(findings)) >= 1),
  author_id       uuid references public.profiles (id),
  created_at      timestamptz not null default now()
);
create table public.prescriptions (
  id          uuid primary key default gen_random_uuid(),
  patient_id  uuid not null references public.patients (id) on delete restrict,
  doctor_id   uuid not null references public.doctors (id) on delete restrict,
  device_type text not null check (length(btrim(device_type)) >= 1),
  details     text,
  status      text not null default 'active' check (status in ('active', 'cancelled')),
  author_id   uuid references public.profiles (id),
  created_at  timestamptz not null default now()
);

-- ---------- patient-shareable reports (separate from internal notes) ----
create table public.shareable_reports (
  id           uuid primary key default gen_random_uuid(),
  patient_id   uuid not null references public.patients (id) on delete restrict,
  title        text not null check (length(btrim(title)) between 1 and 300),
  body         text not null,
  status       text not null default 'draft' check (status in ('draft', 'published', 'withdrawn')),
  published_at timestamptz,
  author_id    uuid references public.profiles (id),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create trigger shareable_reports_updated before update on public.shareable_reports
  for each row execute function public.set_updated_at();

-- Published content is frozen; it can only be withdrawn.
create function public.shareable_reports_guard() returns trigger
language plpgsql as $$
begin
  if old.status = 'published' then
    if new.status <> 'withdrawn' or new.title <> old.title or new.body <> old.body then
      raise exception 'published report is immutable (withdraw it instead)' using errcode = '23514';
    end if;
  elsif old.status = 'withdrawn' then
    raise exception 'withdrawn report cannot be changed' using errcode = '23514';
  end if;
  if new.status = 'published' and old.status = 'draft' then new.published_at := now(); end if;
  return new;
end $$;
create trigger shareable_reports_guard_update before update on public.shareable_reports
  for each row execute function public.shareable_reports_guard();

-- ---------- referrals ---------------------------------------------------
create table public.referrals (
  id                 uuid primary key default gen_random_uuid(),
  patient_id         uuid not null references public.patients (id) on delete restrict,
  referring_doctor_id uuid not null references public.doctors (id) on delete restrict,
  reason             text,
  status             text not null default 'received' check (status in ('received', 'accepted', 'rejected', 'closed')),
  created_by         uuid references public.profiles (id),
  created_at         timestamptz not null default now()
);
create trigger referrals_created_by before insert on public.referrals
  for each row execute function public.set_created_by();

-- authors
create trigger medical_records_author before insert on public.medical_records for each row execute function public.set_author();
create trigger clinical_notes_author  before insert on public.clinical_notes  for each row execute function public.set_author();
create trigger assessments_author     before insert on public.assessments     for each row execute function public.set_author();
create trigger prescriptions_author   before insert on public.prescriptions   for each row execute function public.set_author();
create trigger shareable_reports_author before insert on public.shareable_reports for each row execute function public.set_author();

create index medical_records_patient_idx on public.medical_records (patient_id);
create index clinical_notes_patient_idx  on public.clinical_notes (patient_id);
create index assessments_patient_idx     on public.assessments (patient_id);
create index prescriptions_patient_idx   on public.prescriptions (patient_id);
create index shareable_reports_patient_idx on public.shareable_reports (patient_id);
create index referrals_patient_idx       on public.referrals (patient_id);

-- audit (sensitive clinical operations)
create trigger medical_records_audit after insert or update on public.medical_records for each row execute function public.audit_row_change();
create trigger clinical_notes_audit  after insert or update on public.clinical_notes  for each row execute function public.audit_row_change();
create trigger assessments_audit     after insert or update on public.assessments     for each row execute function public.audit_row_change();
create trigger prescriptions_audit   after insert or update on public.prescriptions   for each row execute function public.audit_row_change();
create trigger shareable_reports_audit after insert or update on public.shareable_reports for each row execute function public.audit_row_change();
create trigger referrals_audit       after insert or update on public.referrals       for each row execute function public.audit_row_change();

-- ---------- privileges + RLS --------------------------------------------
alter table public.medical_records   enable row level security;
alter table public.clinical_notes    enable row level security;
alter table public.assessments       enable row level security;
alter table public.prescriptions     enable row level security;
alter table public.shareable_reports enable row level security;
alter table public.referrals         enable row level security;
alter table public.medical_records   force row level security;
alter table public.clinical_notes    force row level security;
alter table public.assessments       force row level security;
alter table public.prescriptions     force row level security;
alter table public.shareable_reports force row level security;
alter table public.referrals         force row level security;

revoke all on public.medical_records, public.clinical_notes, public.assessments,
              public.prescriptions, public.shareable_reports, public.referrals
  from anon, authenticated;
grant select, insert on public.medical_records, public.clinical_notes, public.assessments,
                        public.prescriptions, public.shareable_reports, public.referrals
  to authenticated;
grant update (status)               on public.prescriptions     to authenticated;
grant update (title, body, status)  on public.shareable_reports to authenticated;
grant update (status, reason)       on public.referrals         to authenticated;

-- append-only internal tables
create policy mr_select on public.medical_records for select to authenticated using (public.can_read_clinical(patient_id));
create policy mr_insert on public.medical_records for insert to authenticated with check (public.can_write_clinical(patient_id));
create policy cn_select on public.clinical_notes  for select to authenticated using (public.can_read_clinical(patient_id));
create policy cn_insert on public.clinical_notes  for insert to authenticated with check (public.can_write_clinical(patient_id));
-- Technical assessments are Phase 3 (case assignment); only clinical ones are accepted now.
create policy as_select on public.assessments     for select to authenticated using (public.can_read_clinical(patient_id));
create policy as_insert on public.assessments     for insert to authenticated
  with check (assessment_type = 'clinical' and public.can_write_clinical(patient_id));

create policy rx_select on public.prescriptions for select to authenticated using (public.can_read_clinical(patient_id));
create policy rx_insert on public.prescriptions for insert to authenticated
  with check (public.can_write_clinical(patient_id)
              and (public.is_doctor_self(doctor_id) or public.has_permission('clinical.read_all')));
create policy rx_update on public.prescriptions for update to authenticated
  using (public.can_write_clinical(patient_id)) with check (public.can_write_clinical(patient_id));

-- shareable reports: patient sees ONLY own published reports
create policy sr_select on public.shareable_reports for select to authenticated
  using (public.can_read_clinical(patient_id)
         or (status = 'published' and public.is_patient_self(patient_id)));
create policy sr_insert on public.shareable_reports for insert to authenticated
  with check (public.can_write_clinical(patient_id));
create policy sr_update on public.shareable_reports for update to authenticated
  using (public.can_write_clinical(patient_id)) with check (public.can_write_clinical(patient_id));

-- referrals: managed by doctors.manage; referring doctor sees own
create policy ref_select on public.referrals for select to authenticated
  using (public.has_permission('doctors.manage') or public.is_doctor_self(referring_doctor_id));
create policy ref_insert on public.referrals for insert to authenticated with check (public.has_permission('doctors.manage'));
create policy ref_update on public.referrals for update to authenticated
  using (public.has_permission('doctors.manage')) with check (public.has_permission('doctors.manage'));
