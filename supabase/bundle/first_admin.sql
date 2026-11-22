-- Promote the FIRST admin. Run once in the Supabase SQL Editor AFTER that person
-- has signed up from the app's login page. Replace the e-mail below.
-- Only works while no active admin exists (guards against misuse).
do $$
declare v_email text := 'REPLACE_WITH_YOUR_EMAIL';
begin
  if exists (select 1 from public.profiles where role = 'admin' and is_active) then
    raise exception 'an active admin already exists';
  end if;
  update public.profiles set role = 'admin', is_active = true
   where lower(email) = lower(v_email);
  if not found then raise exception 'no profile with e-mail %', v_email; end if;
end $$;
