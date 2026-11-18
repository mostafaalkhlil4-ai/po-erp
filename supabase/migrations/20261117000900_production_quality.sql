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
