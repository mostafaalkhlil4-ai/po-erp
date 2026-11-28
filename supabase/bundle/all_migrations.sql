-- Ottobonm P&O ERP: all migrations 0001-0014 in order. Paste into Supabase SQL Editor on a NEW EMPTY project and Run once.
-- If your project already has migrations 0001-0013 applied (41 public tables), run ONLY supabase/migrations/20261128000100_org_settings.sql.

-- ===== 20261116000100_identity_rbac_audit.sql =====
-- =====================================================================
-- Migration 0001: Identity, RBAC, Audit foundation (Phase 1)
-- Target: Supabase PostgreSQL (auth.users / auth.uid() are provided by Supabase)
-- Principles: deny by default, RLS on every table, no privilege escalation
--             through user-controlled data, append-only audit log.
-- =====================================================================

-- ---------- Roles -----------------------------------------------------
create type public.app_role as enum
  ('admin', 'management', 'technician', 'doctor', 'patient');

-- ---------- Generic helpers -------------------------------------------
create function public.set_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;

-- ---------- profiles (application users, 1:1 with auth.users) ---------
create table public.profiles (
  id         uuid primary key references auth.users (id) on delete restrict,
  email      text not null,
  full_name  text not null default '',
  role       public.app_role not null default 'patient',
  -- New accounts are inactive until an authorized user activates them.
  is_active  boolean not null default false,
  locale     text not null default 'ar' check (locale in ('ar', 'en')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index profiles_role_idx on public.profiles (role) where is_active;
create trigger profiles_set_updated_at before update on public.profiles
  for each row execute function public.set_updated_at();

-- ---------- permissions ------------------------------------------------
create table public.permissions (
  code        text primary key,
  description text not null
);

create table public.role_permissions (
  role            public.app_role not null,
  permission_code text not null references public.permissions (code) on delete cascade,
  primary key (role, permission_code)
);

-- ---------- audit_logs (append-only) ----------------------------------
create table public.audit_logs (
  id          bigint generated always as identity primary key,
  actor_id    uuid,                      -- null = system / service role
  action      text not null,             -- INSERT | UPDATE | DELETE | custom
  entity_type text not null,
  entity_id   text,
  old_data    jsonb,
  new_data    jsonb,
  created_at  timestamptz not null default now()
);
create index audit_logs_entity_idx on public.audit_logs (entity_type, entity_id);
create index audit_logs_actor_idx  on public.audit_logs (actor_id, created_at desc);

create function public.audit_logs_immutable() returns trigger
language plpgsql as $$
begin
  raise exception 'audit_logs is append-only';
end $$;
create trigger audit_logs_no_update_delete before update or delete on public.audit_logs
  for each row execute function public.audit_logs_immutable();
create trigger audit_logs_no_truncate before truncate on public.audit_logs
  for each statement execute function public.audit_logs_immutable();

-- ---------- Authorization helpers (SECURITY DEFINER, fixed search_path) -
create function public.current_app_role() returns public.app_role
language sql stable security definer set search_path = '' as $$
  select p.role from public.profiles p where p.id = auth.uid() and p.is_active
$$;

create function public.has_permission(p_code text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1
    from public.profiles pr
    join public.role_permissions rp on rp.role = pr.role
    where pr.id = auth.uid() and pr.is_active and rp.permission_code = p_code
  )
$$;

-- ---------- Audit writer + generic row audit trigger -------------------
create function public.write_audit(
  p_action text, p_entity_type text, p_entity_id text,
  p_old jsonb default null, p_new jsonb default null
) returns void
language sql security definer set search_path = '' as $$
  insert into public.audit_logs (actor_id, action, entity_type, entity_id, old_data, new_data)
  values (auth.uid(), p_action, p_entity_type, p_entity_id, p_old, p_new)
$$;
-- Must not be callable via the API (would allow forging audit entries).
revoke all on function public.write_audit(text, text, text, jsonb, jsonb)
  from public, anon, authenticated;

create function public.audit_row_change() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_id text;
begin
  if tg_op = 'DELETE' then
    v_id := coalesce(to_jsonb(old)->>'id', to_jsonb(old)::text);
    perform public.write_audit(tg_op, tg_table_name, v_id, to_jsonb(old), null);
    return old;
  elsif tg_op = 'UPDATE' then
    v_id := coalesce(to_jsonb(new)->>'id', to_jsonb(new)::text);
    perform public.write_audit(tg_op, tg_table_name, v_id, to_jsonb(old), to_jsonb(new));
    return new;
  else
    v_id := coalesce(to_jsonb(new)->>'id', to_jsonb(new)::text);
    perform public.write_audit(tg_op, tg_table_name, v_id, null, to_jsonb(new));
    return new;
  end if;
end $$;

-- ---------- Profile integrity rules ------------------------------------
-- 1) Only users.manage holders (or trusted server contexts where auth.uid()
--    is null, e.g. service role / migrations) may change role/is_active/email/id.
-- 2) The last active admin can never be demoted or deactivated.
create function public.profiles_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is not null and not public.has_permission('users.manage') then
    if new.id is distinct from old.id
       or new.role is distinct from old.role
       or new.is_active is distinct from old.is_active
       or new.email is distinct from old.email then
      raise exception 'not allowed to change role, status or email'
        using errcode = '42501';
    end if;
  end if;

  if old.role = 'admin' and old.is_active
     and (new.role <> 'admin' or not new.is_active) then
    if not exists (
      select 1 from public.profiles
      where role = 'admin' and is_active and id <> old.id
    ) then
      raise exception 'cannot demote or deactivate the last active admin'
        using errcode = '23514';
    end if;
  end if;
  return new;
end $$;
create trigger profiles_guard_update before update on public.profiles
  for each row execute function public.profiles_guard();

create trigger profiles_audit after insert or update or delete on public.profiles
  for each row execute function public.audit_row_change();
create trigger role_permissions_audit after insert or update or delete on public.role_permissions
  for each row execute function public.audit_row_change();

-- ---------- Signup hook: profile is created with the LOWEST privilege ---
-- Role is never read from user-controlled metadata.
create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, email, full_name)
  values (new.id, coalesce(new.email, ''),
          coalesce(new.raw_user_meta_data->>'full_name', ''));
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- Permission catalogue (baseline; later phases extend) -------
insert into public.permissions (code, description) values
  ('users.manage',        'Create/activate users and change their roles'),
  ('roles.manage',        'Edit role-permission assignments'),
  ('settings.manage',     'Change system settings'),
  ('audit.read',          'Read audit logs'),
  ('patients.read_all',   'Read all patient records'),
  ('patients.write',      'Create/update patient records'),
  ('doctors.manage',      'Manage doctors and referrals'),
  ('cases.read_all',      'Read all cases'),
  ('cases.write',         'Create/update cases and assignments'),
  ('cases.read_assigned', 'Read cases assigned/linked to the user (scope enforced by relationship policies)'),
  ('clinical.write',      'Write clinical assessments, prescriptions and medical reports'),
  ('technical.write',     'Write technical assessments, measurements, design documentation'),
  ('catalog.read',        'Read the product catalog'),
  ('catalog.manage',      'Manage manufacturers, products and prices'),
  ('quotations.manage',   'Create/revise/approve quotations'),
  ('production.overview', 'See production across all cases'),
  ('production.work',     'Work on assigned production tasks, QC, fitting, delivery'),
  ('inventory.manage',    'Manage inventory and stock movements'),
  ('procurement.manage',  'Manage suppliers and purchase orders'),
  ('finance.manage',      'Manage invoices, payments and expenses'),
  ('reports.operational', 'View operational reports'),
  ('appointments.manage', 'Manage appointments and follow-ups'),
  ('portal.self',         'Access own data through the patient portal');

-- Admin: every permission.
insert into public.role_permissions (role, permission_code)
select 'admin', code from public.permissions;

-- Management: operational/administrative, NOT users/roles/settings/audit.
insert into public.role_permissions (role, permission_code) values
  ('management','patients.read_all'), ('management','patients.write'),
  ('management','doctors.manage'),   ('management','cases.read_all'),
  ('management','cases.write'),      ('management','catalog.read'),
  ('management','catalog.manage'),   ('management','quotations.manage'),
  ('management','production.overview'), ('management','inventory.manage'),
  ('management','procurement.manage'),  ('management','finance.manage'),
  ('management','reports.operational'), ('management','appointments.manage');

-- Technician: technical work only; no finance.
insert into public.role_permissions (role, permission_code) values
  ('technician','cases.read_assigned'), ('technician','technical.write'),
  ('technician','production.work'),     ('technician','catalog.read');

-- Doctor: linked patients only; no finance.
insert into public.role_permissions (role, permission_code) values
  ('doctor','cases.read_assigned'), ('doctor','clinical.write'),
  ('doctor','catalog.read'),        ('doctor','appointments.manage');

-- Patient: own data only.
insert into public.role_permissions (role, permission_code) values
  ('patient','portal.self'), ('patient','catalog.read');

-- ---------- Privileges + RLS (deny by default) --------------------------
alter table public.profiles         enable row level security;
alter table public.permissions      enable row level security;
alter table public.role_permissions enable row level security;
alter table public.audit_logs       enable row level security;
alter table public.profiles         force row level security;
alter table public.role_permissions force row level security;
alter table public.audit_logs       force row level security;

revoke all on public.profiles, public.permissions,
              public.role_permissions, public.audit_logs from anon, authenticated;

grant select on public.profiles, public.permissions,
                public.role_permissions, public.audit_logs to authenticated;
grant update (full_name, locale, role, is_active) on public.profiles to authenticated;
grant insert, update, delete on public.role_permissions to authenticated;

-- profiles
create policy profiles_select on public.profiles for select to authenticated
  using (
    id = auth.uid()
    or public.has_permission('users.manage')
    or (public.has_permission('patients.read_all') and role in ('doctor','technician','patient'))
  );
create policy profiles_update on public.profiles for update to authenticated
  using (id = auth.uid() or public.has_permission('users.manage'))
  with check (id = auth.uid() or public.has_permission('users.manage'));

-- permissions catalogue: readable by any signed-in user (no sensitive data)
create policy permissions_select on public.permissions for select to authenticated
  using (true);

-- role_permissions: a user sees their own role's grants; roles.manage sees/edits all
create policy role_permissions_select on public.role_permissions for select to authenticated
  using (role = public.current_app_role() or public.has_permission('roles.manage'));
create policy role_permissions_write on public.role_permissions for all to authenticated
  using (public.has_permission('roles.manage'))
  with check (public.has_permission('roles.manage'));

-- audit_logs: read only with audit.read; no client write path at all
create policy audit_logs_select on public.audit_logs for select to authenticated
  using (public.has_permission('audit.read'));

-- ===== 20261116000200_patients_doctors.sql =====
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

-- ===== 20261116000300_clinical_records.sql =====
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

-- ===== 20261116000400_management_reads_clinical.sql =====
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

-- ===== 20261116000500_portal_account_links.sql =====
-- =====================================================================
-- Migration 0005: portal account links must match the account's role.
-- patients.user_id -> a profile with role 'patient'
-- doctors.user_id  -> a profile with role 'doctor'
-- (uniqueness of user_id already enforced by the unique constraints)
-- =====================================================================
create function public.check_portal_link_role() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_expected public.app_role := tg_argv[0]::public.app_role;
  v_role public.app_role;
begin
  if new.user_id is not null then
    select role into v_role from public.profiles where id = new.user_id;
    if v_role is distinct from v_expected then
      raise exception 'linked account must have role %', v_expected using errcode = '23514';
    end if;
  end if;
  return new;
end $$;
create trigger patients_portal_role before insert or update of user_id on public.patients
  for each row execute function public.check_portal_link_role('patient');
create trigger doctors_portal_role before insert or update of user_id on public.doctors
  for each row execute function public.check_portal_link_role('doctor');

-- ===== 20261116000600_cases_workflow.sql =====
-- =====================================================================
-- Migration 0006: cases, technician assignments, workflow state machine,
-- case events, measurements, technical assessments (Phase 3).
-- * Status can only change through advance_case() (validated transitions,
--   role-checked, event written). No direct UPDATE privilege on status.
-- * Technicians see only cases they are actively assigned to, and the
--   patients of those cases. Doctors: cases of linked patients (read).
--   Patients: own cases (status only; events are internal).
-- * Transition quotation -> approved is BLOCKED until the quotation module
--   exists (Phase 4): an approved quotation is required by the business rules.
-- =====================================================================

create table public.cases (
  id                    uuid primary key default gen_random_uuid(),
  case_no               bigint generated always as identity unique,
  patient_id            uuid not null references public.patients (id) on delete restrict,
  case_type             text not null check (case_type in ('prosthetic', 'orthotic', 'rehabilitation')),
  status                text not null default 'assessment' check (status in
    ('assessment','product_selection','quotation','approved','production',
     'quality_control','fitting','delivered','follow_up','closed','cancelled')),
  priority              text not null default 'normal' check (priority in ('low','normal','high','urgent')),
  responsible_doctor_id uuid references public.doctors (id) on delete restrict,
  opened_at             timestamptz not null default now(),
  closed_at             timestamptz,
  created_by            uuid references public.profiles (id),
  updated_at            timestamptz not null default now()
);
create index cases_patient_idx on public.cases (patient_id);
create index cases_status_idx on public.cases (status);
create trigger cases_set_updated_at before update on public.cases
  for each row execute function public.set_updated_at();
create trigger cases_created_by before insert on public.cases
  for each row execute function public.set_created_by();

create table public.case_assignments (
  id            uuid primary key default gen_random_uuid(),
  case_id       uuid not null references public.cases (id) on delete restrict,
  technician_id uuid not null references public.profiles (id) on delete restrict,
  assigned_at   timestamptz not null default now(),
  ended_at      timestamptz,
  created_by    uuid references public.profiles (id),
  check (ended_at is null or ended_at >= assigned_at)
);
create unique index case_assignments_one_active on public.case_assignments (case_id, technician_id) where ended_at is null;
create index case_assignments_tech_idx on public.case_assignments (technician_id) where ended_at is null;
create trigger case_assignments_created_by before insert on public.case_assignments
  for each row execute function public.set_created_by();

create table public.case_events (
  id         bigint generated always as identity primary key,
  case_id    uuid not null references public.cases (id) on delete restrict,
  event_type text not null check (event_type in ('created','status_change','assignment','unassignment')),
  from_status text,
  to_status   text,
  note        text,
  actor_id    uuid,
  created_at  timestamptz not null default now()
);
create index case_events_case_idx on public.case_events (case_id, created_at);
create trigger case_events_immutable_u before update or delete on public.case_events
  for each row execute function public.audit_logs_immutable();

create table public.case_transitions (
  from_status text not null,
  to_status   text not null,
  actor_kind  text not null check (actor_kind in ('staff', 'technician')),
  primary key (from_status, to_status, actor_kind)
);
insert into public.case_transitions values
  ('assessment','product_selection','staff'),
  ('product_selection','quotation','staff'),
  ('quotation','approved','staff'),            -- guarded in advance_case until Phase 4
  ('approved','production','staff'),
  ('production','quality_control','staff'), ('production','quality_control','technician'),
  ('quality_control','production','staff'), ('quality_control','production','technician'),
  ('quality_control','fitting','staff'),    ('quality_control','fitting','technician'),
  ('fitting','delivered','staff'),          ('fitting','delivered','technician'),
  ('delivered','follow_up','staff'),
  ('follow_up','closed','staff'),
  ('closed','follow_up','staff'),           -- reopen (authorized staff only)
  ('assessment','cancelled','staff'), ('product_selection','cancelled','staff'),
  ('quotation','cancelled','staff'),   ('approved','cancelled','staff');

create table public.measurements (
  id         uuid primary key default gen_random_uuid(),
  case_id    uuid not null references public.cases (id) on delete restrict,
  label      text not null check (length(btrim(label)) between 1 and 100),
  value      numeric(10,2) not null,
  unit       text not null check (unit in ('mm','cm','kg','deg')),
  side       text check (side in ('left','right')),
  notes      text,
  author_id  uuid references public.profiles (id),
  created_at timestamptz not null default now()
);
create index measurements_case_idx on public.measurements (case_id);
create trigger measurements_author before insert on public.measurements
  for each row execute function public.set_author();

alter table public.assessments add column case_id uuid references public.cases (id) on delete restrict;
create index assessments_case_idx on public.assessments (case_id);

-- ---------- helpers ----------------------------------------------------
create function public.is_assigned_tech(p_case uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select public.current_app_role() = 'technician' and exists (
    select 1 from public.case_assignments a
    where a.case_id = p_case and a.technician_id = auth.uid() and a.ended_at is null)
$$;

create function public.is_tech_of_patient(p_patient uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select public.current_app_role() = 'technician' and exists (
    select 1 from public.case_assignments a join public.cases c on c.id = a.case_id
    where c.patient_id = p_patient and a.technician_id = auth.uid() and a.ended_at is null)
$$;

create function public.case_patient(p_case uuid) returns uuid
language sql stable security definer set search_path = '' as $$
  select patient_id from public.cases where id = p_case
$$;

-- staff/technician/doctor view of a case (patients excluded: they get no internal data)
create function public.can_read_case_internal(p_case uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select public.has_permission('cases.read_all')
      or public.is_assigned_tech(p_case)
      or public.is_doctor_of(public.case_patient(p_case))
$$;

create function public.case_is_open(p_case uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.cases where id = p_case and status not in ('closed','cancelled'))
$$;

-- ---------- triggers ---------------------------------------------------
create function public.cases_after_insert() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.case_events (case_id, event_type, to_status, actor_id)
  values (new.id, 'created', new.status, auth.uid());
  return new;
end $$;
create trigger cases_event_created after insert on public.cases
  for each row execute function public.cases_after_insert();

create function public.case_assignments_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    if not exists (select 1 from public.profiles where id = new.technician_id and role = 'technician' and is_active) then
      raise exception 'assignee must be an active technician' using errcode = '23514';
    end if;
    if not public.case_is_open(new.case_id) then
      raise exception 'case is closed or cancelled' using errcode = '23514';
    end if;
    insert into public.case_events (case_id, event_type, note, actor_id)
    values (new.case_id, 'assignment', new.technician_id::text, auth.uid());
  else
    if old.ended_at is null and new.ended_at is not null then
      insert into public.case_events (case_id, event_type, note, actor_id)
      values (new.case_id, 'unassignment', new.technician_id::text, auth.uid());
    end if;
  end if;
  return new;
end $$;
create trigger case_assignments_guard_t before insert or update on public.case_assignments
  for each row execute function public.case_assignments_guard();

create function public.require_open_case() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if not public.case_is_open(new.case_id) then
    raise exception 'case is closed or cancelled' using errcode = '23514';
  end if;
  return new;
end $$;
create trigger measurements_open_case before insert on public.measurements
  for each row execute function public.require_open_case();

create trigger cases_audit before insert or update on public.cases for each row execute function public.audit_row_change();
create trigger case_assignments_audit after insert or update on public.case_assignments for each row execute function public.audit_row_change();
create trigger measurements_audit after insert on public.measurements for each row execute function public.audit_row_change();

-- ---------- state machine ---------------------------------------------
create function public.advance_case(p_case uuid, p_to text, p_note text default null) returns void
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
    -- technicians never learn more than "not allowed"; staff get a precise message
    if v_staff and exists (select 1 from public.case_transitions where from_status = v_from and to_status = p_to) is false then
      raise exception 'invalid transition % -> %', v_from, p_to using errcode = '23514';
    end if;
    raise exception 'transition % -> % not allowed for this user', v_from, p_to using errcode = case when v_staff then '23514' else '42501' end;
  end if;
  if v_from = 'quotation' and p_to = 'approved' then
    raise exception 'requires an approved quotation (quotation module not implemented yet)' using errcode = '0A000';
  end if;
  update public.cases
     set status = p_to,
         closed_at = case when p_to = 'closed' then now() when v_from = 'closed' then null else closed_at end
   where id = p_case;
  insert into public.case_events (case_id, event_type, from_status, to_status, note, actor_id)
  values (p_case, 'status_change', v_from, p_to, p_note, auth.uid());
end $$;
revoke all on function public.advance_case(uuid, text, text) from public, anon;
grant execute on function public.advance_case(uuid, text, text) to authenticated;

-- ---------- privileges + RLS ------------------------------------------
alter table public.cases            enable row level security;
alter table public.case_assignments enable row level security;
alter table public.case_events      enable row level security;
alter table public.case_transitions enable row level security;
alter table public.measurements     enable row level security;
alter table public.cases            force row level security;
alter table public.case_assignments force row level security;
alter table public.case_events      force row level security;
alter table public.case_transitions force row level security;
alter table public.measurements     force row level security;

revoke all on public.cases, public.case_assignments, public.case_events,
              public.case_transitions, public.measurements from anon, authenticated;
grant select, insert on public.cases, public.case_assignments, public.measurements to authenticated;
grant select on public.case_events, public.case_transitions to authenticated;
grant update (priority, responsible_doctor_id) on public.cases to authenticated;
grant update (ended_at) on public.case_assignments to authenticated;

create policy cases_select on public.cases for select to authenticated
  using (public.has_permission('cases.read_all') or public.is_assigned_tech(id)
         or public.is_doctor_of(patient_id) or public.is_patient_self(patient_id));
create policy cases_insert on public.cases for insert to authenticated
  with check (public.has_permission('cases.write') and status = 'assessment');
create policy cases_update on public.cases for update to authenticated
  using (public.has_permission('cases.write')) with check (public.has_permission('cases.write'));

create policy ca_select on public.case_assignments for select to authenticated
  using (public.has_permission('cases.read_all') or technician_id = auth.uid());
create policy ca_insert on public.case_assignments for insert to authenticated
  with check (public.has_permission('cases.write'));
create policy ca_update on public.case_assignments for update to authenticated
  using (public.has_permission('cases.write')) with check (public.has_permission('cases.write'));

create policy ce_select on public.case_events for select to authenticated
  using (public.can_read_case_internal(case_id));
create policy ct_select on public.case_transitions for select to authenticated using (true);

create policy me_select on public.measurements for select to authenticated
  using (public.can_read_case_internal(case_id));
create policy me_insert on public.measurements for insert to authenticated
  with check (public.is_assigned_tech(case_id) or public.has_permission('clinical.manage'));

-- technicians: patients of their active cases (demographics only)
create policy patients_select_tech on public.patients for select to authenticated
  using (public.is_tech_of_patient(id));

-- technical assessments by the assigned technician (clinical ones stay doctor/admin)
create policy as_select_tech on public.assessments for select to authenticated
  using (assessment_type = 'technical' and case_id is not null and public.is_assigned_tech(case_id));
create policy as_insert_tech on public.assessments for insert to authenticated
  with check (assessment_type = 'technical' and case_id is not null
              and public.is_assigned_tech(case_id)
              and public.case_patient(case_id) = patient_id
              and public.has_permission('technical.write'));

-- ===== 20261116000700_devices_appointments_attachments.sql =====
-- =====================================================================
-- Migration 0007: devices, components, appointments, follow-ups, attachments.
-- Devices here are case-level descriptions (free text). Linking to catalog
-- products comes with the catalog (Phase 4); nothing is invented here.
-- Attachments: metadata row + PRIVATE storage object. The metadata row is the
-- single source of authorization for both the table and storage.objects.
-- =====================================================================

-- ---------- devices ----------------------------------------------------
create table public.devices (
  id          uuid primary key default gen_random_uuid(),
  case_id     uuid not null references public.cases (id) on delete restrict,
  device_type text not null check (length(btrim(device_type)) between 1 and 200),
  side        text check (side in ('left', 'right', 'both')),
  description text,
  created_by  uuid references public.profiles (id),
  created_at  timestamptz not null default now()
);
create index devices_case_idx on public.devices (case_id);
create trigger devices_created_by before insert on public.devices for each row execute function public.set_created_by();
create trigger devices_open_case before insert on public.devices for each row execute function public.require_open_case();

create function public.device_case(p_device uuid) returns uuid
language sql stable security definer set search_path = '' as $$
  select case_id from public.devices where id = p_device
$$;

create table public.device_components (
  id         uuid primary key default gen_random_uuid(),
  device_id  uuid not null references public.devices (id) on delete restrict,
  name       text not null check (length(btrim(name)) between 1 and 200),
  notes      text,
  created_by uuid references public.profiles (id),
  created_at timestamptz not null default now()
);
create index device_components_device_idx on public.device_components (device_id);
create trigger device_components_created_by before insert on public.device_components for each row execute function public.set_created_by();

-- ---------- appointments -----------------------------------------------
create table public.appointments (
  id               uuid primary key default gen_random_uuid(),
  patient_id       uuid not null references public.patients (id) on delete restrict,
  case_id          uuid references public.cases (id) on delete restrict,
  appointment_type text not null check (appointment_type in ('assessment','fitting','follow_up','consultation','other')),
  scheduled_at     timestamptz not null,
  status           text not null default 'scheduled' check (status in ('scheduled','completed','cancelled','no_show')),
  notes            text,
  created_by       uuid references public.profiles (id),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index appointments_patient_idx on public.appointments (patient_id, scheduled_at);
create index appointments_case_idx on public.appointments (case_id);
create trigger appointments_updated before update on public.appointments for each row execute function public.set_updated_at();
create trigger appointments_created_by before insert on public.appointments for each row execute function public.set_created_by();
create function public.appointments_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.case_id is not null and public.case_patient(new.case_id) is distinct from new.patient_id then
    raise exception 'case does not belong to this patient' using errcode = '23514';
  end if;
  return new;
end $$;
create trigger appointments_guard_t before insert or update on public.appointments for each row execute function public.appointments_guard();

-- ---------- follow-ups --------------------------------------------------
create table public.follow_ups (
  id                 uuid primary key default gen_random_uuid(),
  case_id            uuid not null references public.cases (id) on delete restrict,
  due_date           date not null,
  status             text not null default 'planned' check (status in ('planned','done','cancelled')),
  technical_feedback text,
  device_issues      text,
  author_id          uuid references public.profiles (id),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
create index follow_ups_case_idx on public.follow_ups (case_id);
create trigger follow_ups_updated before update on public.follow_ups for each row execute function public.set_updated_at();
create trigger follow_ups_author before insert on public.follow_ups for each row execute function public.set_author();
create function public.follow_ups_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.cases where id = new.case_id and status in ('delivered', 'follow_up')) then
    raise exception 'follow-ups are only allowed after delivery' using errcode = '23514';
  end if;
  return new;
end $$;
create trigger follow_ups_guard_t before insert on public.follow_ups for each row execute function public.follow_ups_guard();

-- ---------- attachments --------------------------------------------------
create table public.attachments (
  id           uuid primary key default gen_random_uuid(),
  patient_id   uuid not null references public.patients (id) on delete restrict,
  case_id      uuid references public.cases (id) on delete restrict,
  category     text not null check (category in ('photo','document','design','report','other')),
  visibility   text not null default 'internal' check (visibility in ('internal','shared')),
  storage_path text not null unique,
  file_name    text not null check (length(file_name) between 1 and 255),
  mime_type    text not null check (mime_type in ('image/jpeg','image/png','image/webp','application/pdf')),
  size_bytes   bigint not null check (size_bytes > 0 and size_bytes <= 26214400),
  uploaded_by  uuid references public.profiles (id),
  created_at   timestamptz not null default now(),
  -- path is generated by the server: patients/<patient_id>/<uuid>.<ext> (no user-controlled path parts)
  check (storage_path ~ '^patients/[0-9a-f-]{36}/[0-9a-f-]{36}\.(jpg|png|webp|pdf)$'),
  check (split_part(storage_path, '/', 2) = patient_id::text)
);
create index attachments_patient_idx on public.attachments (patient_id);
create index attachments_case_idx on public.attachments (case_id);
create function public.set_uploader() returns trigger language plpgsql as $$
begin new.uploaded_by := auth.uid(); return new; end $$;
create trigger attachments_uploader before insert on public.attachments
  for each row execute function public.set_uploader();

create function public.attachment_row_readable(p_patient uuid, p_case uuid, p_visibility text) returns boolean
language sql stable security definer set search_path = '' as $$
  select public.has_permission('clinical.read_all')
      or public.is_doctor_of(p_patient)
      or (p_case is not null and public.is_assigned_tech(p_case))
      or (p_visibility = 'shared' and public.is_patient_self(p_patient))
$$;

create function public.attachment_path_readable(p_path text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.attachments a
                 where a.storage_path = p_path
                   and public.attachment_row_readable(a.patient_id, a.case_id, a.visibility))
$$;

create function public.attachment_path_uploadable(p_path text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.attachments a
                 where a.storage_path = p_path and a.uploaded_by = auth.uid())
$$;

create trigger devices_audit after insert or update on public.devices for each row execute function public.audit_row_change();
create trigger appointments_audit after insert or update on public.appointments for each row execute function public.audit_row_change();
create trigger follow_ups_audit after insert or update on public.follow_ups for each row execute function public.audit_row_change();
create trigger attachments_audit after insert on public.attachments for each row execute function public.audit_row_change();

-- ---------- privileges + RLS --------------------------------------------
alter table public.devices           enable row level security;
alter table public.device_components enable row level security;
alter table public.appointments      enable row level security;
alter table public.follow_ups        enable row level security;
alter table public.attachments       enable row level security;
alter table public.devices           force row level security;
alter table public.device_components force row level security;
alter table public.appointments      force row level security;
alter table public.follow_ups        force row level security;
alter table public.attachments       force row level security;

revoke all on public.devices, public.device_components, public.appointments, public.follow_ups, public.attachments
  from anon, authenticated;
grant select, insert on public.devices, public.device_components, public.appointments, public.follow_ups, public.attachments to authenticated;
grant update (description, side) on public.devices to authenticated;
grant update (scheduled_at, status, notes) on public.appointments to authenticated;
grant update (due_date, status, technical_feedback, device_issues) on public.follow_ups to authenticated;

create policy dev_select on public.devices for select to authenticated using (public.can_read_case_internal(case_id));
create policy dev_insert on public.devices for insert to authenticated
  with check (public.has_permission('cases.write') or public.is_assigned_tech(case_id));
create policy dev_update on public.devices for update to authenticated
  using (public.has_permission('cases.write') or public.is_assigned_tech(case_id))
  with check (public.has_permission('cases.write') or public.is_assigned_tech(case_id));

create policy dc_select on public.device_components for select to authenticated
  using (public.can_read_case_internal(public.device_case(device_id)));
create policy dc_insert on public.device_components for insert to authenticated
  with check (public.has_permission('cases.write') or public.is_assigned_tech(public.device_case(device_id)));

create policy ap_select on public.appointments for select to authenticated
  using (public.has_permission('cases.read_all')
         or public.is_doctor_of(patient_id)
         or public.is_patient_self(patient_id)
         or (case_id is not null and public.is_assigned_tech(case_id)));
create policy ap_insert on public.appointments for insert to authenticated
  with check (public.has_permission('cases.write')
              or (public.has_permission('appointments.manage') and public.is_doctor_of(patient_id)));
create policy ap_update on public.appointments for update to authenticated
  using (public.has_permission('cases.write')
         or (public.has_permission('appointments.manage') and public.is_doctor_of(patient_id)))
  with check (public.has_permission('cases.write')
              or (public.has_permission('appointments.manage') and public.is_doctor_of(patient_id)));

create policy fu_select on public.follow_ups for select to authenticated using (public.can_read_case_internal(case_id));
create policy fu_insert on public.follow_ups for insert to authenticated
  with check (public.has_permission('cases.write') or public.is_assigned_tech(case_id));
create policy fu_update on public.follow_ups for update to authenticated
  using (public.has_permission('cases.write') or public.is_assigned_tech(case_id))
  with check (public.has_permission('cases.write') or public.is_assigned_tech(case_id));

create policy att_select on public.attachments for select to authenticated
  using (public.attachment_row_readable(patient_id, case_id, visibility));
create policy att_insert on public.attachments for insert to authenticated
  with check ((case_id is null or public.case_patient(case_id) = patient_id)
              and (public.has_permission('cases.write')
                   or public.is_doctor_of(patient_id)
                   or (case_id is not null and public.is_assigned_tech(case_id))));

-- ---------- private storage bucket ---------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('attachments', 'attachments', false, 26214400,
        array['image/jpeg','image/png','image/webp','application/pdf'])
on conflict (id) do nothing;

-- Objects: authorization is delegated to the metadata row (see functions above).
-- No UPDATE/DELETE policies: stored files are immutable.
create policy attachments_obj_select on storage.objects for select to authenticated
  using (bucket_id = 'attachments' and public.attachment_path_readable(name));
create policy attachments_obj_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'attachments' and public.attachment_path_uploadable(name));

-- ===== 20261117000800_catalog_quotations.sql =====
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
  seq          bigint generated always as identity,   -- stable insertion order (created_at ties inside one transaction)
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
         ) order by i.seq), '[]'::jsonb)
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
      from public.quotation_items where quotation_id = p_q order by seq;
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

-- ===== 20261117000900_production_quality.sql =====
-- =====================================================================
-- Migration 0009: Production stages and quality control (Phase 5, D-026)
-- Stages are created by staff or the assigned technician while the case is
-- approved/production; status changes only through set_stage_status().
-- QC results are append-only. advance_case() gates production->quality_control
-- (all stages completed) and quality_control->fitting (a passing QC recorded
-- after the case entered quality_control).
-- =====================================================================
create table public.production_stages (
  id             uuid primary key default gen_random_uuid(),
  case_id        uuid not null references public.cases (id) on delete restrict,
  name           text not null check (length(btrim(name)) between 1 and 100),
  position       int  not null default 0 check (position >= 0),
  status         text not null default 'pending' check (status in ('pending','in_progress','completed')),
  responsible_id uuid references public.profiles (id),
  started_at     timestamptz,
  completed_at   timestamptz,
  notes          text,
  created_by     uuid references public.profiles (id),
  created_at     timestamptz not null default now(),
  check ((status = 'pending') = (started_at is null)),
  check ((status = 'completed') = (completed_at is not null))
);
create index production_stages_case_idx on public.production_stages (case_id, position);
create trigger production_stages_created_by before insert on public.production_stages
  for each row execute function public.set_created_by();
create trigger production_stages_open_case before insert on public.production_stages
  for each row execute function public.require_open_case();

create function public.stage_case_status_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.cases where id = new.case_id and status in ('approved','production')) then
    raise exception 'production stages can only be planned for approved or in-production cases' using errcode = '23514';
  end if;
  return new;
end $$;
create trigger production_stages_case_status before insert on public.production_stages
  for each row execute function public.stage_case_status_guard();
-- clients can only insert pending stages
create function public.stage_insert_defaults() returns trigger
language plpgsql as $$
begin
  new.status := 'pending'; new.started_at := null; new.completed_at := null; new.responsible_id := null;
  return new;
end $$;
create trigger production_stages_defaults before insert on public.production_stages
  for each row execute function public.stage_insert_defaults();

create function public.set_stage_status(p_stage uuid, p_to text, p_notes text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare s public.production_stages; v_ok boolean;
begin
  select * into s from public.production_stages where id = p_stage for update;
  if s.id is null then raise exception 'stage not found' using errcode = 'P0002'; end if;
  v_ok := auth.uid() is not null and (
            public.has_permission('cases.write')
            or (public.is_assigned_tech(s.case_id) and public.has_permission('production.work')));
  if not v_ok then raise exception 'not allowed to update this stage' using errcode = '42501'; end if;
  if not exists (select 1 from public.cases where id = s.case_id and status = 'production') then
    raise exception 'stage work requires the case to be in production' using errcode = '23514';
  end if;
  if not ((s.status = 'pending' and p_to = 'in_progress') or (s.status = 'in_progress' and p_to = 'completed')) then
    raise exception 'invalid stage transition % -> %', s.status, p_to using errcode = '23514';
  end if;
  update public.production_stages
     set status = p_to,
         responsible_id = coalesce(responsible_id, auth.uid()),
         started_at = coalesce(started_at, now()),
         completed_at = case when p_to = 'completed' then now() end,
         notes = coalesce(p_notes, notes)
   where id = p_stage;
end $$;
revoke all on function public.set_stage_status(uuid, text, text) from public, anon;
grant execute on function public.set_stage_status(uuid, text, text) to authenticated;
-- rows are changed only by set_stage_status (SECURITY DEFINER owner); block everything else
create function public.stage_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then raise exception 'stages cannot be deleted' using errcode = '42501'; end if;
  if old.status = 'completed' then raise exception 'completed stage is immutable' using errcode = '23514'; end if;
  if new.case_id <> old.case_id or new.name <> old.name or new.created_at <> old.created_at then
    raise exception 'stage identity is immutable' using errcode = '23514';
  end if;
  return new;
end $$;
create trigger production_stages_guard before update or delete on public.production_stages
  for each row execute function public.stage_guard();
create trigger production_stages_audit after insert or update on public.production_stages
  for each row execute function public.audit_row_change();

create table public.quality_checks (
  id         bigint generated always as identity primary key,
  case_id    uuid not null references public.cases (id) on delete restrict,
  result     text not null check (result in ('pass','fail')),
  notes      text check (result = 'pass' or length(btrim(coalesce(notes,''))) > 0),
  checked_by uuid references public.profiles (id),
  created_at timestamptz not null default clock_timestamp()
);
create index quality_checks_case_idx on public.quality_checks (case_id, id);
create function public.quality_check_defaults() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.checked_by := auth.uid();
  new.created_at := clock_timestamp();
  if not exists (select 1 from public.cases where id = new.case_id and status = 'quality_control') then
    raise exception 'quality checks can only be recorded while the case is in quality_control' using errcode = '23514';
  end if;
  return new;
end $$;
create trigger quality_checks_defaults before insert on public.quality_checks
  for each row execute function public.quality_check_defaults();
create trigger quality_checks_immutable before update or delete on public.quality_checks
  for each row execute function public.audit_logs_immutable();
create trigger quality_checks_audit after insert on public.quality_checks
  for each row execute function public.audit_row_change();

-- ---------- advance_case with production / QC gates ---------------------
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
  if v_from = 'production' and p_to = 'quality_control' then
    if not exists (select 1 from public.production_stages where case_id = p_case)
       or exists (select 1 from public.production_stages where case_id = p_case and status <> 'completed') then
      raise exception 'all production stages must exist and be completed before quality control' using errcode = '23514';
    end if;
  end if;
  if v_from = 'quality_control' and p_to = 'fitting' then
    if not coalesce((
         select qc.result = 'pass' and qc.created_at >= coalesce(
                  (select max(e.created_at) from public.case_events e where e.case_id = p_case and e.to_status = 'quality_control'), '-infinity')
           from public.quality_checks qc where qc.case_id = p_case order by qc.id desc limit 1), false) then
      raise exception 'a passing quality check is required before fitting' using errcode = '23514';
    end if;
  end if;
  update public.cases
     set status = p_to,
         closed_at = case when p_to = 'closed' then now() when v_from = 'closed' then null else closed_at end
   where id = p_case;
  insert into public.case_events (case_id, event_type, from_status, to_status, note, actor_id)
  values (p_case, 'status_change', v_from, p_to, p_note, auth.uid());
end $$;

-- ---------- privileges + RLS ----------------------------------------------
alter table public.production_stages enable row level security;
alter table public.quality_checks    enable row level security;
alter table public.production_stages force row level security;
alter table public.quality_checks    force row level security;
revoke all on public.production_stages, public.quality_checks from anon, authenticated;
grant select, insert on public.production_stages, public.quality_checks to authenticated;
grant usage on sequence public.quality_checks_id_seq to authenticated;

create policy ps_select on public.production_stages for select to authenticated
  using (public.can_read_case_internal(case_id));
create policy ps_insert on public.production_stages for insert to authenticated
  with check (public.has_permission('cases.write')
              or (public.is_assigned_tech(case_id) and public.has_permission('production.work')));
create policy qc_select on public.quality_checks for select to authenticated
  using (public.can_read_case_internal(case_id));
create policy qc_insert on public.quality_checks for insert to authenticated
  with check (public.has_permission('cases.write')
              or (public.is_assigned_tech(case_id) and public.has_permission('production.work')));

-- ===== 20261117001000_finance.sql =====
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

-- ===== 20261117001100_inventory_procurement.sql =====
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

-- ===== 20261117001200_patient_billing_portal.sql =====
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

-- ===== 20261117001300_patient_billing_sharing.sql =====
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

-- ===== 20261128000100_org_settings.sql =====
-- General-manager settings (D-036): one row holding the centre's identity, entered manually by an admin.
-- Nothing is seeded. Only settings.manage holders (admin) can read or write; every change is audited.
create table public.org_settings (
  id          boolean primary key default true check (id),   -- single-row table
  center_name text check (center_name is null or length(btrim(center_name)) between 1 and 200),
  phone       text check (phone is null or length(phone) <= 50),
  email       text check (email is null or length(email) <= 200),
  address     text check (address is null or length(address) <= 500),
  updated_by  uuid references public.profiles (id),
  updated_at  timestamptz not null default now()
);

create function public.org_settings_stamp() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.updated_by := auth.uid();
  new.updated_at := now();
  return new;
end $$;
revoke all on function public.org_settings_stamp() from public;

create trigger org_settings_stamp before insert or update on public.org_settings
  for each row execute function public.org_settings_stamp();
create trigger org_settings_audit after insert or update on public.org_settings
  for each row execute function public.audit_row_change();

alter table public.org_settings enable row level security;
alter table public.org_settings force row level security;
create policy org_settings_select on public.org_settings for select to authenticated
  using (public.has_permission('settings.manage'));
create policy org_settings_insert on public.org_settings for insert to authenticated
  with check (public.has_permission('settings.manage'));
create policy org_settings_update on public.org_settings for update to authenticated
  using (public.has_permission('settings.manage')) with check (public.has_permission('settings.manage'));

revoke all on public.org_settings from anon, authenticated;
grant select, insert, update (center_name, phone, email, address) on public.org_settings to authenticated;
