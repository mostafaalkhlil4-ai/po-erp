-- General-manager settings (D-036). Synthetic values only.
do $$
declare
  admin_id uuid := '00000000-0000-0000-0000-0000000000a1';
  mgmt uuid := '00000000-0000-0000-0000-0000000000a2';
  tech uuid := '00000000-0000-0000-0000-0000000000a3';
  doc  uuid := '00000000-0000-0000-0000-0000000000a4';
  pat1 uuid := '00000000-0000-0000-0000-0000000000a5';
  n int;
begin
  perform tests.eq('T110a nothing seeded', (select count(*) from public.org_settings)::int, 0);

  perform tests.login(mgmt);
  perform tests.expect_error('T111a management cannot write settings', 'insert into public.org_settings (center_name) values (''X'')', '42501');
  perform tests.eq('T111b management cannot read settings', (select count(*) from public.org_settings)::int, 0);
  perform tests.logout();
  perform tests.login(tech);
  perform tests.expect_error('T111c technician cannot write settings', 'insert into public.org_settings (center_name) values (''X'')', '42501');
  perform tests.logout();
  perform tests.login(doc);
  perform tests.expect_error('T111d doctor cannot write settings', 'insert into public.org_settings (center_name) values (''X'')', '42501');
  perform tests.logout();
  perform tests.login(pat1);
  perform tests.expect_error('T111e patient cannot write settings', 'insert into public.org_settings (center_name) values (''X'')', '42501');
  perform tests.logout();
  perform tests.anon();
  perform tests.expect_error('T111f anon denied settings', 'select * from public.org_settings', '42501');
  perform tests.logout();

  perform tests.login(admin_id);
  insert into public.org_settings (center_name, phone) values ('Demo Centre', '000');
  perform tests.eq('T112a admin can insert and read', (select count(*) from public.org_settings)::int, 1);
  perform tests.eq('T112b updated_by is set server-side', (select updated_by from public.org_settings), admin_id);
  perform tests.expect_error('T112c second row rejected', 'insert into public.org_settings (id, center_name) values (false, ''Y'')', '23514');
  perform tests.expect_error('T112d empty name rejected', 'update public.org_settings set center_name = ''   ''', '23514');
  perform tests.expect_error('T112e client cannot forge updated_by', format('update public.org_settings set updated_by = %L', mgmt), '42501');
  update public.org_settings set address = 'Demo address';
  perform tests.eq('T112f update works', (select address from public.org_settings), 'Demo address');
  perform tests.expect_error('T112g no delete', 'delete from public.org_settings', '42501');
  perform tests.logout();

  select count(*) into n from public.audit_logs where entity_type = 'org_settings';
  perform tests.eq('T113a settings changes are audited', n >= 2, true);
end $$;
