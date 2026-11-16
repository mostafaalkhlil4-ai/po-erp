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
