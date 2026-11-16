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
