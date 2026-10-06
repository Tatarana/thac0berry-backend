-- Permissões da Fase 1: cada usuário só vê e altera o que é dele.
begin;
create extension if not exists pgtap with schema extensions;
select plan(20);

insert into auth.users (id, email, aud, role) values
  ('11111111-1111-1111-1111-111111111111', 'a@teste.dev', 'authenticated', 'authenticated'),
  ('22222222-2222-2222-2222-222222222222', 'b@teste.dev', 'authenticated', 'authenticated');

-- ---- Usuário A cria uma biblioteca completa ----
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);

insert into public.user_preferences (favorite_spell_ids) values ('{pri_cure_light_wounds}');
insert into public.campaign (id, name) values ('c0000000-0000-0000-0000-00000000000a', 'Campanha A');
insert into public.session (id, campaign_id, date)
  values ('50000000-0000-0000-0000-00000000000a', 'c0000000-0000-0000-0000-00000000000a', now());
insert into public.character (id, campaign_id, data)
  values ('ca000000-0000-0000-0000-00000000000a', 'c0000000-0000-0000-0000-00000000000a',
          '{"name":"Kelmon","characterClass":"Cleric","level":11,"status":"alive"}');
insert into public.spell_sheet (id, character_id, session_id, data)
  values ('5b000000-0000-0000-0000-00000000000a', 'ca000000-0000-0000-0000-00000000000a',
          '50000000-0000-0000-0000-00000000000a', '{"title":"Day 1"}');
-- Caderno por personagem (2026-10-06): a página é do personagem; a campanha é opcional.
insert into public.notebook_entry (id, character_id, campaign_id, title)
  values ('0b000000-0000-0000-0000-00000000000a', 'ca000000-0000-0000-0000-00000000000a',
          'c0000000-0000-0000-0000-00000000000a', 'Notas de A');
select throws_ok(
  $$ insert into public.notebook_entry (id, campaign_id)
     values ('0b000000-0000-0000-0000-0000000000a2', 'c0000000-0000-0000-0000-00000000000a') $$,
  '42501', null, 'página nova sem personagem é recusada');

select results_eq(
  $$ select name, character_class, level, status from public.character $$,
  $$ values ('Kelmon'::text, 'Cleric'::text, 11, 'alive'::text) $$,
  'resumo da ficha é calculado a partir do JSON');

-- Nem o dono apaga linha: sem GRANT de DELETE (exclusão é marcação em deleted_at).
select throws_ok($$ delete from public.character where id = 'ca000000-0000-0000-0000-00000000000a' $$,
                 '42501', null, 'DELETE é negado (exclusão só por deleted_at)');

-- ---- Usuário B não vê nada de A ----
select set_config('request.jwt.claims', '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}', true);

select is((select count(*) from public.user_preferences), 0::bigint, 'B não vê preferências de A');
select is((select count(*) from public.campaign),         0::bigint, 'B não vê campanhas de A');
select is((select count(*) from public.session),          0::bigint, 'B não vê sessões de A');
select is((select count(*) from public.character),        0::bigint, 'B não vê personagens de A');
select is((select count(*) from public.spell_sheet),      0::bigint, 'B não vê folhas de A');
select is((select count(*) from public.notebook_entry),   0::bigint, 'B não vê o caderno de A');

-- B tenta alterar a ficha de A: nada acontece.
update public.character set data = '{"name":"Hackeado"}' where id = 'ca000000-0000-0000-0000-00000000000a';

-- B tenta pendurar coisas suas nos registros de A: bloqueado.
select throws_ok(
  $$ insert into public.spell_sheet (id, character_id, data)
     values ('5b000000-0000-0000-0000-00000000000b', 'ca000000-0000-0000-0000-00000000000a', '{}') $$,
  '42501', null, 'B não cria folha no personagem de A');
select throws_ok(
  $$ insert into public.character (id, campaign_id, data)
     values ('ca000000-0000-0000-0000-00000000000b', 'c0000000-0000-0000-0000-00000000000a', '{}') $$,
  '42501', null, 'B não cria personagem na campanha de A');
select throws_ok(
  $$ insert into public.notebook_entry (id, campaign_id)
     values ('0b000000-0000-0000-0000-00000000000b', 'c0000000-0000-0000-0000-00000000000a') $$,
  '42501', null, 'B não escreve no caderno da campanha de A');
select throws_ok(
  $$ insert into public.notebook_entry (id, character_id)
     values ('0b000000-0000-0000-0000-00000000000c', 'ca000000-0000-0000-0000-00000000000a') $$,
  '42501', null, 'B não escreve no caderno do personagem de A');
select throws_ok(
  $$ insert into public.character (id, owner_id, data)
     values ('ca000000-0000-0000-0000-00000000000c', '11111111-1111-1111-1111-111111111111', '{}') $$,
  '42501', null, 'B não cria personagem em nome de A');

-- B tem a própria biblioteca normalmente (Sandbox: personagem sem campanha).
insert into public.character (id, data) values ('ca000000-0000-0000-0000-00000000000d', '{"name":"Borin"}');
select is((select count(*) from public.character), 1::bigint, 'B vê só o próprio personagem');
-- …e o caderno dele, mesmo no Sandbox (sem campanha).
insert into public.notebook_entry (id, character_id, title)
  values ('0b000000-0000-0000-0000-00000000000d', 'ca000000-0000-0000-0000-00000000000d', 'Notas de Borin');
select is((select count(*) from public.notebook_entry), 1::bigint, 'B tem caderno no personagem do Sandbox');

-- ---- Anônimo (sem login) não vê nada ----
reset role;
set local role anon;
select throws_ok($$ select count(*) from public.campaign $$,  '42501', null, 'anônimo: acesso negado a campanhas');
select throws_ok($$ select count(*) from public.character $$, '42501', null, 'anônimo: acesso negado a personagens');

-- ---- Conferência como administrador ----
reset role;
select is((select data ->> 'name' from public.character where id = 'ca000000-0000-0000-0000-00000000000a'),
          'Kelmon', 'a ficha de A não foi alterada por B');
select is((select count(*) from public.character), 2::bigint, 'as duas fichas existem (A e B)');

select * from finish();
rollback;
