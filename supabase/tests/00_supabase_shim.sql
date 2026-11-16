-- LOCAL TEST ONLY. Emulates the parts of Supabase that migrations depend on.
-- Never applied to a real Supabase project (it already provides all of this).
create role anon nologin;
create role authenticated nologin;
create role service_role nologin bypassrls;

create schema auth;
create table auth.users (
  id uuid primary key default gen_random_uuid(),
  email text,
  raw_user_meta_data jsonb not null default '{}'::jsonb
);
create function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;

grant usage on schema public, auth to anon, authenticated, service_role;
-- Supabase grants broad default privileges; our migration must restrict them.
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
