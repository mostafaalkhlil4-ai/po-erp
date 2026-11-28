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
