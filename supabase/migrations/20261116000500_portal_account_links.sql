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
