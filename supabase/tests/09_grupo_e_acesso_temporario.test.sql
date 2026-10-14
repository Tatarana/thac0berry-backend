-- Fase 2c (2026-10-13): o grupo vê o resumo das fichas (nome, classe, nível, PV);
-- o mestre dá acesso temporário à ficha de quem faltou; quem recebeu edita, mas
-- não apaga nem tira da campanha; o acesso cai ao revogar, expirar ou sair.
begin;
create extension if not exists pgtap with schema extensions;
select plan(18);

insert into auth.users (id, email, aud, role) values
  ('dddddddd-0000-0000-0000-000000000001', 'mestre4@teste.dev', 'authenticated', 'authenticated'),
  ('dddddddd-0000-0000-0000-000000000002', 'ausente@teste.dev', 'authenticated', 'authenticated'),
  ('dddddddd-0000-0000-0000-000000000003', 'cobre@teste.dev', 'authenticated', 'authenticated'),
  ('dddddddd-0000-0000-0000-000000000004', 'fora@teste.dev', 'authenticated', 'authenticated');

select has_table('public', 'character_grant', 'tabela de acessos temporários');

set local role authenticated;

select set_config('request.jwt.claims', '{"sub":"dddddddd-0000-0000-0000-000000000001","role":"authenticated"}', true);
insert into public.campaign (id, name) values ('c3000000-0000-0000-0000-000000000001', 'Mesa C');
select public.set_campaign_invite('c3000000-0000-0000-0000-000000000001', 'MESA-GRUPO');

-- A jogadora que vai faltar põe a ficha na campanha.
select set_config('request.jwt.claims', '{"sub":"dddddddd-0000-0000-0000-000000000002","role":"authenticated"}', true);
select public.join_campaign('MESA-GRUPO', 'Ana');
insert into public.character (id, campaign_id, data)
  values ('cd000000-0000-0000-0000-000000000001', 'c3000000-0000-0000-0000-000000000001',
          '{"name":"Ana, a Clériga","characterClass":"Cleric","level":5,"hitPointsCurrent":21,"hitPointsMax":33}');

-- O outro jogador: vê o resumo, não a ficha.
select set_config('request.jwt.claims', '{"sub":"dddddddd-0000-0000-0000-000000000003","role":"authenticated"}', true);
select public.join_campaign('MESA-GRUPO', 'Caio');
select is((select count(*)::int from public.character), 0, 'sem acesso, o outro jogador não lê a ficha');
select is(
  (select player_name || ': ' || name || ' ' || hit_points_current || '/' || hit_points_max from public.campaign_party('c3000000-0000-0000-0000-000000000001')),
  'Ana: Ana, a Clériga 21/33', 'mas vê o resumo no grupo (nome de quem joga, PV)');
select ok(not (select can_edit from public.campaign_party('c3000000-0000-0000-0000-000000000001')), 'e o resumo diz que não pode abrir a ficha');
select throws_ok($$select public.grant_character_access('cd000000-0000-0000-0000-000000000001', 'dddddddd-0000-0000-0000-000000000003')$$,
  '42501', 'not_gm', 'só o mestre dá acesso');

-- Quem é de fora não vê nem o resumo.
select set_config('request.jwt.claims', '{"sub":"dddddddd-0000-0000-0000-000000000004","role":"authenticated"}', true);
select throws_ok($$select * from public.campaign_party('c3000000-0000-0000-0000-000000000001')$$, '42501', 'not_member', 'quem é de fora não vê o grupo');

-- O mestre dá acesso ao Caio (não à dona, e com prazo válido).
select set_config('request.jwt.claims', '{"sub":"dddddddd-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok($$select public.grant_character_access('cd000000-0000-0000-0000-000000000001', 'dddddddd-0000-0000-0000-000000000002')$$,
  '22023', 'invalid_grantee', 'não se dá acesso à própria dona');
select throws_ok($$select public.grant_character_access('cd000000-0000-0000-0000-000000000001', 'dddddddd-0000-0000-0000-000000000003', 0)$$,
  '22023', 'invalid_hours', 'prazo de 1 a 168 horas');
select lives_ok($$select public.grant_character_access('cd000000-0000-0000-0000-000000000001', 'dddddddd-0000-0000-0000-000000000003')$$,
  'o mestre dá acesso por 24 h');
select ok((select expires_at between now() + interval '23 hours' and now() + interval '25 hours' from public.character_grant), 'com prazo de 24 h');

-- Caio, com acesso: lê, edita, cria folha; não apaga nem tira da campanha.
select set_config('request.jwt.claims', '{"sub":"dddddddd-0000-0000-0000-000000000003","role":"authenticated"}', true);
select is((select count(*)::int from public.character), 1, 'com acesso, o jogador lê a ficha');
update public.character set data = jsonb_set(data, '{hitPointsCurrent}', '12'), version = 1 where id = 'cd000000-0000-0000-0000-000000000001';
select is((select hit_points_current from public.campaign_party('c3000000-0000-0000-0000-000000000001')), 12, 'e edita (o resumo mostra os PV novos)');
insert into public.spell_sheet (id, character_id, data) values ('5d000000-0000-0000-0000-000000000001', 'cd000000-0000-0000-0000-000000000001', '{"title":"Dia 1"}');
select is((select owner_id from public.spell_sheet), 'dddddddd-0000-0000-0000-000000000002'::uuid, 'a folha que ele cria fica no nome da dona');
select throws_ok($$update public.character set deleted_at = now() where id = 'cd000000-0000-0000-0000-000000000001'$$,
  '42501', 'owner_only', 'com acesso, não apaga a ficha');

-- Devolve o acesso: deixa de ler.
select public.revoke_character_access((select id from public.character_grant where revoked_at is null));
select is((select count(*)::int from public.character), 0, 'quem recebeu devolve o acesso e deixa de ler');

-- Novo acesso; o jogador sai da campanha e o acesso cai junto.
select set_config('request.jwt.claims', '{"sub":"dddddddd-0000-0000-0000-000000000001","role":"authenticated"}', true);
select public.grant_character_access('cd000000-0000-0000-0000-000000000001', 'dddddddd-0000-0000-0000-000000000003', 2);
select set_config('request.jwt.claims', '{"sub":"dddddddd-0000-0000-0000-000000000003","role":"authenticated"}', true);
select is((select count(*)::int from public.character), 1, 'o novo acesso vale');
select public.remove_campaign_member('c3000000-0000-0000-0000-000000000001', 'dddddddd-0000-0000-0000-000000000003');
select is((select count(*)::int from public.character), 0, 'saiu da campanha: o acesso deixa de valer');

-- Expirado também não vale (direto na tabela: o tempo não passa no teste).
select public.join_campaign('MESA-GRUPO');
reset role;
update public.character_grant set expires_at = now() - interval '1 minute', revoked_at = null;
set local role authenticated;
select is((select count(*)::int from public.character), 0, 'de volta à campanha, mas com o acesso expirado: não vale');

reset role;
select * from finish();
rollback;
