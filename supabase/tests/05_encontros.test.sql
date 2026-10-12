-- Encontros do Combat Tracker e campanha ativa na conta (2026-10-12): só o dono
-- lê e grava; o encontro só entra em campanha do próprio dono; versão e conflito
-- como nas outras tabelas.
begin;
create extension if not exists pgtap with schema extensions;
select plan(11);

insert into auth.users (id, email, aud, role) values
  ('55555555-5555-5555-5555-555555555555', 'e@teste.dev', 'authenticated', 'authenticated'),
  ('66666666-6666-6666-6666-666666666666', 'f@teste.dev', 'authenticated', 'authenticated');

select has_table('public', 'encounter', 'tabela de encontros');
select has_column('public', 'user_preferences', 'dm_active_campaign_id', 'coluna da campanha ativa');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"55555555-5555-5555-5555-555555555555","role":"authenticated"}', true);

insert into public.campaign (id, name, started_date, notes, is_archived)
  values ('a0000000-0000-0000-0000-000000000001', 'Ravenloft', now(), '', false);
insert into public.encounter (id, campaign_id, data)
  values ('e0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000001', '{"name":"Wolves","round":1,"combatants":[]}');
insert into public.encounter (id, campaign_id, data)
  values ('e0000000-0000-0000-0000-000000000002', null, '{"name":"One-shot fight","round":0,"combatants":[]}');
select is((select count(*)::int from public.encounter), 2, 'o dono cria encontro com e sem campanha');
select is((select name from public.encounter where id = 'e0000000-0000-0000-0000-000000000001'), 'Wolves', 'nome gerado do JSON');

update public.encounter set data = '{"name":"Wolves","round":2,"combatants":[],"endedAt":"2026-10-12T20:00:00Z"}', version = 1
  where id = 'e0000000-0000-0000-0000-000000000001';
select is((select version from public.encounter where id = 'e0000000-0000-0000-0000-000000000001'), 2::bigint, 'UPDATE com a versão conhecida sobe a versão');
select ok((select ended and conflicted_at is null from public.encounter where id = 'e0000000-0000-0000-0000-000000000001'), 'encerrado, sem conflito');

update public.encounter set data = '{"name":"Wolves","round":3,"combatants":[]}', version = 1
  where id = 'e0000000-0000-0000-0000-000000000001';
select ok((select conflicted_at is not null from public.encounter where id = 'e0000000-0000-0000-0000-000000000001'), 'gravação baseada em versão antiga fica marcada');

insert into public.user_preferences (dm_active_campaign_id, combat_settings)
  values ('a0000000-0000-0000-0000-000000000001', '{"initiative":"individual","monsterHp":"average","deathAt":0}');
select is((select combat_settings ->> 'initiative' from public.user_preferences), 'individual', 'configurações do Combat Tracker na conta');

-- Outro usuário: não vê, não altera e não põe encontro na campanha alheia.
select set_config('request.jwt.claims', '{"sub":"66666666-6666-6666-6666-666666666666","role":"authenticated"}', true);
select is((select count(*)::int from public.encounter), 0, 'outro usuário não vê os encontros');
update public.encounter set data = '{"name":"Hack"}' where id = 'e0000000-0000-0000-0000-000000000002';
select throws_ok(
  $$insert into public.encounter (id, campaign_id, data) values ('e0000000-0000-0000-0000-000000000003', 'a0000000-0000-0000-0000-000000000001', '{"name":"x"}')$$,
  '42501', null, 'não cria encontro em campanha de outro');
reset role;
select is((select name from public.encounter where id = 'e0000000-0000-0000-0000-000000000002'), 'One-shot fight', 'outro usuário não altera');

select * from finish();
rollback;
