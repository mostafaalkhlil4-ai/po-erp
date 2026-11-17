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
