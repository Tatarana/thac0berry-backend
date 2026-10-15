-- Combat Tracker interativo, I1 (2026-10-15): mensagens entre o mestre e os
-- jogadores. O jogador manda só pelo próprio personagem e só com o encontro
-- mostrado; o mestre manda ao personagem da campanha; quem recebe aceita ou
-- recusa; quem mandou retira; ninguém escreve direto; cada um só lê o seu.
begin;
create extension if not exists pgtap with schema extensions;
select plan(16);

insert into auth.users (id, email, aud, role) values
  ('cdcdcdcd-0000-0000-0000-000000000001', 'mestre8@teste.dev', 'authenticated', 'authenticated'),
  ('cdcdcdcd-0000-0000-0000-000000000002', 'jog8a@teste.dev', 'authenticated', 'authenticated'),
  ('cdcdcdcd-0000-0000-0000-000000000003', 'jog8b@teste.dev', 'authenticated', 'authenticated');

select has_table('public', 'combat_message', 'tabela das mensagens do combate');
select ok(exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'combat_message'),
  'as mensagens estão na publicação do Realtime');

-- O mestre cria a campanha e o encontro; os dois jogadores entram, cada um com o seu personagem.
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"cdcdcdcd-0000-0000-0000-000000000001","role":"authenticated"}', true);
insert into public.campaign (id, name) values ('c8000000-0000-0000-0000-000000000001', 'Mesa I');
select public.set_campaign_invite('c8000000-0000-0000-0000-000000000001', 'MESA-INTERATIVA');
insert into public.encounter (id, campaign_id, data)
  values ('e8000000-0000-0000-0000-000000000001', 'c8000000-0000-0000-0000-000000000001', '{"name":"Bridge","round":1,"combatants":[]}');

select set_config('request.jwt.claims', '{"sub":"cdcdcdcd-0000-0000-0000-000000000002","role":"authenticated"}', true);
select public.join_campaign('MESA-INTERATIVA', 'Ana');
insert into public.character (id, campaign_id, data) values ('ca800000-0000-0000-0000-000000000001', 'c8000000-0000-0000-0000-000000000001', '{"name":"Ana","hitPointsCurrent":8,"hitPointsMax":8}');

select set_config('request.jwt.claims', '{"sub":"cdcdcdcd-0000-0000-0000-000000000003","role":"authenticated"}', true);
select public.join_campaign('MESA-INTERATIVA', 'Bia');
insert into public.character (id, campaign_id, data) values ('ca800000-0000-0000-0000-000000000002', 'c8000000-0000-0000-0000-000000000001', '{"name":"Bia","hitPointsCurrent":6,"hitPointsMax":6}');

-- Sem a vista publicada, o jogador não manda.
select set_config('request.jwt.claims', '{"sub":"cdcdcdcd-0000-0000-0000-000000000002","role":"authenticated"}', true);
select throws_ok(
  $$select public.send_to_dm('e8000000-0000-0000-0000-000000000001', 'ca800000-0000-0000-0000-000000000001', 'initiative', '{"roll":7}')$$,
  '42501', null, 'encontro não mostrado: o jogador não manda');

select set_config('request.jwt.claims', '{"sub":"cdcdcdcd-0000-0000-0000-000000000001","role":"authenticated"}', true);
select public.publish_encounter_view('e8000000-0000-0000-0000-000000000001', '{"v":1,"name":"Bridge"}');

-- A jogadora manda a iniciativa pelo próprio personagem; não pelo da outra.
select set_config('request.jwt.claims', '{"sub":"cdcdcdcd-0000-0000-0000-000000000002","role":"authenticated"}', true);
select lives_ok(
  $$select public.send_to_dm('e8000000-0000-0000-0000-000000000001', 'ca800000-0000-0000-0000-000000000001', 'initiative', '{"roll":7}')$$,
  'a jogadora manda a iniciativa do próprio personagem');
select throws_ok(
  $$select public.send_to_dm('e8000000-0000-0000-0000-000000000001', 'ca800000-0000-0000-0000-000000000002', 'initiative', '{"roll":1}')$$,
  '42501', null, 'nem pelo personagem de outra jogadora');
select throws_ok(
  $$insert into public.combat_message (campaign_id, encounter_id, character_id, direction, kind, payload) values ('c8000000-0000-0000-0000-000000000001', 'e8000000-0000-0000-0000-000000000001', 'ca800000-0000-0000-0000-000000000001', 'to_dm', 'initiative', '{"roll":1}')$$,
  '42501', null, 'ninguém escreve direto na tabela');
-- Não aceita a própria mensagem (quem aceita é o mestre).
select throws_ok(
  $$select public.resolve_combat_message((select id from public.combat_message limit 1), true)$$,
  '42501', null, 'a jogadora não aceita a própria mensagem');

-- A outra jogadora não vê a mensagem da Ana.
select set_config('request.jwt.claims', '{"sub":"cdcdcdcd-0000-0000-0000-000000000003","role":"authenticated"}', true);
select is((select count(*)::int from public.combat_message), 0, 'a outra jogadora não vê as mensagens da Ana');

-- O mestre vê, aceita; e manda dano ao personagem da Ana.
select set_config('request.jwt.claims', '{"sub":"cdcdcdcd-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is((select count(*)::int from public.combat_message where status = 'pending'), 1, 'o mestre vê a mensagem pendente');
select public.resolve_combat_message((select id from public.combat_message where kind = 'initiative'), true);
select is((select status from public.combat_message where kind = 'initiative'), 'accepted', 'o mestre aceita');
select throws_ok(
  $$select public.resolve_combat_message((select id from public.combat_message where kind = 'initiative'), false)$$,
  '22023', null, 'resolvida não muda mais');
select lives_ok(
  $$select public.send_to_player('e8000000-0000-0000-0000-000000000001', 'ca800000-0000-0000-0000-000000000001', 'hp', '{"delta":-3}')$$,
  'o mestre manda dano ao personagem da campanha');
select public.send_to_player('e8000000-0000-0000-0000-000000000001', 'ca800000-0000-0000-0000-000000000001', 'hp', '{"delta":-1}');
select public.withdraw_combat_message((select id from public.combat_message where payload ->> 'delta' = '-1'));
select is((select status from public.combat_message where payload ->> 'delta' = '-1'), 'withdrawn', 'o mestre retira o que mandou');

-- A outra jogadora não manda ao personagem como se fosse o mestre.
select set_config('request.jwt.claims', '{"sub":"cdcdcdcd-0000-0000-0000-000000000003","role":"authenticated"}', true);
select throws_ok(
  $$select public.send_to_player('e8000000-0000-0000-0000-000000000001', 'ca800000-0000-0000-0000-000000000001', 'hp', '{"delta":-50}')$$,
  '42501', null, 'jogador não manda como mestre');

-- A Ana recusa o dano (o mestre não aceita por ela).
select set_config('request.jwt.claims', '{"sub":"cdcdcdcd-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok(
  $$select public.resolve_combat_message((select id from public.combat_message where payload ->> 'delta' = '-3'), true)$$,
  '42501', null, 'o mestre não aceita o dano pela jogadora');
select set_config('request.jwt.claims', '{"sub":"cdcdcdcd-0000-0000-0000-000000000002","role":"authenticated"}', true);
select public.resolve_combat_message((select id from public.combat_message where payload ->> 'delta' = '-3'), false);
select is((select status from public.combat_message where payload ->> 'delta' = '-3'), 'declined', 'a jogadora recusa o dano');

select * from finish();
rollback;
