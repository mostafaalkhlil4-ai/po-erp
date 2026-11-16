-- =====================================================================
-- Migration 0002: patients, doctors, doctor-patient relationships (Phase 2)
-- Demographics only. Medical notes / records live in separate tables (later)
-- so patient-shareable data never mixes with internal clinical notes.
-- No DELETE privilege on any table: history is preserved (archive instead).
-- =====================================================================

create table public.patients (
  id            uuid primary key default gen_random_uuid(),
  file_no       bigint generated always as identity unique,
  user_id       uuid unique references public.profiles (id) on delete restrict, -- portal account
  full_name     text not null check (length(btrim(full_name)) between 2 and 200),
  date_of_birth date check (date_of_birth <= current_date),
  sex           text check (sex in ('male', 'female')),
  phone         text check (phone is null or length(phone) between 5 and 30),
  email         text check (email is null or email like '%_@_%'),
  address       text,
  is_archived   boolean not null default false,
  created_by    uuid references public.profiles (id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
-- Duplicate-registration guard (workflow step 1): same name + birth date + phone.
create unique index patients_duplicate_guard
  on public.patients (lower(btrim(full_name)), date_of_birth, coalesce(phone, ''));
create trigger patients_set_updated_at before update on public.patients
  for each row execute function public.set_updated_at();

create table public.doctors (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid unique references public.profiles (id) on delete restrict, -- portal account
  full_name  text not null check (length(btrim(full_name)) between 2 and 200),
  specialty  text,
  license_no text,
  phone      text,
  is_active  boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger doctors_set_updated_at before update on public.doctors
  for each row execute function public.set_updated_at();

create table public.doctor_patient_relationships (
  id         uuid primary key default gen_random_uuid(),
  doctor_id  uuid not null references public.doctors (id) on delete restrict,
  patient_id uuid not null references public.patients (id) on delete restrict,
  started_at timestamptz not null default now(),
  ended_at   timestamptz,
  created_by uuid references public.profiles (id),
  check (ended_at is null or ended_at >= started_at)
);
-- At most one ACTIVE link per doctor/patient pair.
create unique index dpr_one_active on public.doctor_patient_relationships (doctor_id, patient_id)
  where ended_at is null;
create index dpr_patient_idx on public.doctor_patient_relationships (patient_id) where ended_at is null;

-- ---------- Relationship helpers (SECURITY DEFINER; avoid RLS recursion) --
create function public.is_doctor_of(p_patient uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1
    from public.doctors d
    join public.doctor_patient_relationships r on r.doctor_id = d.id
    where d.user_id = auth.uid() and d.is_active
      and r.patient_id = p_patient and r.ended_at is null
      and public.current_app_role() = 'doctor'
  )
$$;

create function public.is_patient_self(p_patient uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.patients p
    where p.id = p_patient and p.user_id = auth.uid() and public.current_app_role() = 'patient'
  )
$$;

create function public.is_doctor_self(p_doctor uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.doctors d
    where d.id = p_doctor and d.user_id = auth.uid() and public.current_app_role() = 'doctor'
  )
$$;

-- A patient may see the doctors currently linked to them.
create function public.is_my_doctor(p_doctor uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1
    from public.doctor_patient_relationships r
    join public.patients p on p.id = r.patient_id
    where r.doctor_id = p_doctor and r.ended_at is null
      and p.user_id = auth.uid() and public.current_app_role() = 'patient'
  )
$$;

-- Record who created a patient/link (cannot be spoofed by the client).
create function public.set_created_by() returns trigger
language plpgsql as $$
begin
  new.created_by := auth.uid();
  return new;
end $$;
create trigger patients_created_by before insert on public.patients
  for each row execute function public.set_created_by();
create trigger dpr_created_by before insert on public.doctor_patient_relationships
  for each row execute function public.set_created_by();

create trigger patients_audit after insert or update on public.patients
  for each row execute function public.audit_row_change();
create trigger doctors_audit after insert or update on public.doctors
  for each row execute function public.audit_row_change();
create trigger dpr_audit after insert or update on public.doctor_patient_relationships
  for each row execute function public.audit_row_change();

-- ---------- Permissions for new capability ----------------------------
-- Doctors/patients get data through relationship RLS, not through *.read_all.

-- ---------- Privileges + RLS ------------------------------------------
alter table public.patients                     enable row level security;
alter table public.doctors                      enable row level security;
alter table public.doctor_patient_relationships enable row level security;
alter table public.patients                     force row level security;
alter table public.doctors                      force row level security;
alter table public.doctor_patient_relationships force row level security;

revoke all on public.patients, public.doctors, public.doctor_patient_relationships
  from anon, authenticated;
grant select, insert on public.patients, public.doctors, public.doctor_patient_relationships to authenticated;
grant update (full_name, date_of_birth, sex, phone, email, address, is_archived, user_id)
  on public.patients to authenticated;
grant update (full_name, specialty, license_no, phone, is_active, user_id)
  on public.doctors to authenticated;
grant update (ended_at) on public.doctor_patient_relationships to authenticated;

-- patients
create policy patients_select on public.patients for select to authenticated
  using (public.has_permission('patients.read_all')
         or public.is_patient_self(id)
         or public.is_doctor_of(id));
create policy patients_insert on public.patients for insert to authenticated
  with check (public.has_permission('patients.write'));
create policy patients_update on public.patients for update to authenticated
  using (public.has_permission('patients.write'))
  with check (public.has_permission('patients.write'));

-- doctors
create policy doctors_select on public.doctors for select to authenticated
  using (public.has_permission('doctors.manage')
         or public.is_doctor_self(id)
         or public.is_my_doctor(id));
create policy doctors_insert on public.doctors for insert to authenticated
  with check (public.has_permission('doctors.manage'));
create policy doctors_update on public.doctors for update to authenticated
  using (public.has_permission('doctors.manage'))
  with check (public.has_permission('doctors.manage'));

-- relationships
create policy dpr_select on public.doctor_patient_relationships for select to authenticated
  using (public.has_permission('doctors.manage')
         or public.is_doctor_self(doctor_id)
         or public.is_patient_self(patient_id));
create policy dpr_insert on public.doctor_patient_relationships for insert to authenticated
  with check (public.has_permission('doctors.manage'));
create policy dpr_update on public.doctor_patient_relationships for update to authenticated
  using (public.has_permission('doctors.manage'))
  with check (public.has_permission('doctors.manage'));
