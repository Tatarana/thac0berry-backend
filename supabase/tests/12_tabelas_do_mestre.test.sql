-- GT5 (2026-10-14): tabelas do mestre — só ele lê e grava; com campanha dele ou
-- sem campanha (One-shot); nem jogador da campanha nem outro mestre veem.
begin;
create extension if not exists pgtap with schema extensions;
select plan(8);

insert into auth.users (id, email, aud, role) values
  ('ffffffff-0000-0000-0000-000000000001', 'mestre6@teste.dev', 'authenticated', 'authenticated'),
  ('ffffffff-0000-0000-0000-000000000002', 'jog6@teste.dev', 'authenticated', 'authenticated');

select has_table('public', 'dm_table', 'tabela das tabelas do mestre');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"ffffffff-0000-0000-0000-000000000001","role":"authenticated"}', true);
insert into public.campaign (id, name) values ('c6000000-0000-0000-0000-000000000001', 'Mesa T');
select public.set_campaign_invite('c6000000-0000-0000-0000-000000000001', 'MESA-TABELAS');
insert into public.dm_table (id, campaign_id, data)
  values ('da000000-0000-0000-0000-000000000001', 'c6000000-0000-0000-0000-000000000001', '{"title":"Forest Encounters","dice":"1d8+1d12","headers":["Roll","Encounter"],"rows":[["2","Dragon"]]}');
insert into public.dm_table (id, campaign_id, data)
  values ('da000000-0000-0000-0000-000000000002', null, '{"title":"One-shot Loot","dice":"d6","headers":["d6","Loot"],"rows":[]}');
select is((select count(*)::int from public.dm_table), 2, 'o mestre cria tabela na campanha e no One-shot');
select is((select name from public.dm_table where id = 'da000000-0000-0000-0000-000000000001'), 'Forest Encounters', 'nome tirado do título');
update public.dm_table set data = jsonb_set(data, '{title}', '"Deep Forest"'), version = 1 where id = 'da000000-0000-0000-0000-000000000001';
select ok((select version = 2 and conflicted_at is null from public.dm_table where id = 'da000000-0000-0000-0000-000000000001'), 'edição com a versão certa, sem conflito');

-- A jogadora da campanha não vê nem cria.
select set_config('request.jwt.claims', '{"sub":"ffffffff-0000-0000-0000-000000000002","role":"authenticated"}', true);
select public.join_campaign('MESA-TABELAS', 'Iara');
select is((select count(*)::int from public.dm_table), 0, 'a jogadora da campanha não vê as tabelas do mestre');
select throws_ok(
  $$insert into public.dm_table (id, campaign_id, data) values ('da000000-0000-0000-0000-000000000003', 'c6000000-0000-0000-0000-000000000001', '{"title":"x"}')$$,
  '42501', null, 'nem cria tabela na campanha do mestre');
update public.dm_table set data = '{"title":"hack"}' where id = 'da000000-0000-0000-0000-000000000002';
reset role;
select is((select name from public.dm_table where id = 'da000000-0000-0000-0000-000000000002'), 'One-shot Loot', 'nem edita');
select is((select count(*)::int from information_schema.role_table_grants where table_name = 'dm_table' and grantee = 'authenticated' and privilege_type = 'DELETE'), 0, 'ninguém apaga a linha (exclusão marcada)');

select * from finish();
rollback;
