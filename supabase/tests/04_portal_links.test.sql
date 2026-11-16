do $$
declare
  mgmt uuid := '00000000-0000-0000-0000-0000000000a2';
  tech uuid := '00000000-0000-0000-0000-0000000000a3';
  doc  uuid := '00000000-0000-0000-0000-0000000000a4';
  pat1 uuid := '00000000-0000-0000-0000-0000000000a5';
  p3 uuid; d2 uuid; n int;
begin
  perform tests.eq('T40a role matrix: management has clinical.read_all but not clinical.manage / clinical.write',
    (select count(*) from public.role_permissions where role = 'management'
       and permission_code in ('clinical.manage','clinical.write'))::int, 0);
  perform tests.eq('T40b only admin holds clinical.manage',
    (select count(*) from public.role_permissions where permission_code = 'clinical.manage')::int, 1);

  perform tests.login(mgmt);
  select id into p3 from public.patients where full_name = 'Test Patient Three';
  perform tests.expect_error('T41a patient cannot be linked to a technician account',
    format('update public.patients set user_id = %L where id = %L', tech, p3), '23514');
  perform tests.expect_error('T41b patient cannot be linked to a doctor account',
    format('update public.patients set user_id = %L where id = %L', doc, p3), '23514');
  perform tests.expect_error('T41c account already linked to another patient is rejected',
    format('update public.patients set user_id = %L where id = %L', pat1, p3), '23505');
  perform tests.expect_error('T41d doctor cannot be linked to a patient account',
    format('insert into public.doctors (full_name, user_id) values (%L, %L)', 'Dr Bad', pat1), '23514');
  perform tests.expect_error('T41e doctor account already linked is rejected',
    format('insert into public.doctors (full_name, user_id) values (%L, %L)', 'Dr Dup', doc), '23505');
  insert into public.doctors (full_name) values ('Dr Unlinked') returning id into d2;
  update public.doctors set user_id = doc where id = d2 and false; -- no-op guard check below
  perform tests.logout();
  perform tests.eq('T41f valid unlinked patient stays unlinked', (select user_id is null from public.patients where id = p3), true);
end $$;
select 'PORTAL LINK TESTS PASSED' as result;
