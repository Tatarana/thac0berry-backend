-- Combat Tracker ao vivo, L1 (2026-10-14): a vista dos jogadores de um
-- encontro. Só o mestre publica (encontro de campanha dele); os membros da
-- campanha leem; quem é de fora não; ninguém escreve direto na tabela; está
-- na publicação do Realtime.
begin;
create extension if not exists pgtap with schema extensions;
select plan(12);

insert into auth.users (id, email, aud, role) values
  ('abababab-0000-0000-0000-000000000001', 'mestre7@teste.dev', 'authenticated', 'authenticated'),
  ('abababab-0000-0000-0000-000000000002', 'jog7@teste.dev', 'authenticated', 'authenticated'),
  ('abababab-0000-0000-0000-000000000003', 'fora7@teste.dev', 'authenticated', 'authenticated');

select has_table('public', 'encounter_view', 'tabela da vista dos jogadores');
select ok(exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'encounter_view'),
  'a vista está na publicação do Realtime');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"abababab-0000-0000-0000-000000000001","role":"authenticated"}', true);
insert into public.campaign (id, name) values ('c7000000-0000-0000-0000-000000000001', 'Mesa V');
select public.set_campaign_invite('c7000000-0000-0000-0000-000000000001', 'MESA-VISTA');
insert into public.encounter (id, campaign_id, data)
  values ('e7000000-0000-0000-0000-000000000001', 'c7000000-0000-0000-0000-000000000001', '{"name":"Ambush","round":1,"combatants":[]}');
insert into public.encounter (id, campaign_id, data)
  values ('e7000000-0000-0000-0000-000000000002', null, '{"name":"One-shot fight","round":0,"combatants":[]}');

select lives_ok(
  $$select public.publish_encounter_view('e7000000-0000-0000-0000-000000000001', '{"name":"Ambush","round":1}')$$,
  'o mestre publica a vista do encontro da campanha');
select lives_ok(
  $$select public.publish_encounter_view('e7000000-0000-0000-0000-000000000001', '{"name":"Ambush","round":2}')$$,
  'publicar de novo substitui a vista');
select is((select (data ->> 'round')::int from public.encounter_view), 2, 'uma vista por encontro, com o dado mais novo');
select throws_ok(
  $$select public.publish_encounter_view('e7000000-0000-0000-0000-000000000002', '{"name":"x"}')$$,
  '22023', null, 'encontro sem campanha (One-shot) não tem vista');

-- A jogadora da campanha lê, mas não publica nem escreve direto.
select set_config('request.jwt.claims', '{"sub":"abababab-0000-0000-0000-000000000002","role":"authenticated"}', true);
select public.join_campaign('MESA-VISTA', 'Iara');
select is((select data ->> 'name' from public.encounter_view), 'Ambush', 'a jogadora da campanha lê a vista');
select throws_ok(
  $$select public.publish_encounter_view('e7000000-0000-0000-0000-000000000001', '{"name":"hack"}')$$,
  '42501', null, 'a jogadora não publica');
select throws_ok(
  $$update public.encounter_view set data = '{"name":"hack"}'$$,
  '42501', null, 'nem escreve direto na tabela');

-- Quem é de fora não vê.
select set_config('request.jwt.claims', '{"sub":"abababab-0000-0000-0000-000000000003","role":"authenticated"}', true);
select is((select count(*)::int from public.encounter_view), 0, 'quem não é da campanha não vê');
select public.unpublish_encounter_view('e7000000-0000-0000-0000-000000000001');
reset role;
select is((select count(*)::int from public.encounter_view), 1, 'e não tira a vista de ninguém');

-- O mestre tira.
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"abababab-0000-0000-0000-000000000001","role":"authenticated"}', true);
select public.unpublish_encounter_view('e7000000-0000-0000-0000-000000000001');
reset role;
select is((select count(*)::int from public.encounter_view), 0, 'o mestre tira a vista dos jogadores');

select * from finish();
rollback;
