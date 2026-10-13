-- Fase 2a (2026-10-13): o mestre gera ou escolhe o código; o jogador entra com
-- ele e passa a ler a campanha, os membros e as sessões; sai ou é removido; a
-- campanha apagada tira os jogadores; quem é de fora não vê nada.
begin;
create extension if not exists pgtap with schema extensions;
select plan(25);

insert into auth.users (id, email, aud, role) values
  ('77777777-7777-7777-7777-777777777777', 'mestre@teste.dev', 'authenticated', 'authenticated'),
  ('88888888-8888-8888-8888-888888888888', 'jogador@teste.dev', 'authenticated', 'authenticated'),
  ('99999999-9999-9999-9999-999999999999', 'outro@teste.dev', 'authenticated', 'authenticated');

select has_table('public', 'campaign_member', 'tabela de membros');
select has_table('public', 'campaign_invite', 'tabela de convites');

set local role authenticated;

-- Mestre: cria duas campanhas e vira `gm` nelas.
select set_config('request.jwt.claims', '{"sub":"77777777-7777-7777-7777-777777777777","role":"authenticated"}', true);
insert into public.campaign (id, name) values ('c0000000-0000-0000-0000-000000000001', 'Sigil');
insert into public.campaign (id, name) values ('c0000000-0000-0000-0000-000000000002', 'Outra');
select is((select role from public.campaign_member where campaign_id = 'c0000000-0000-0000-0000-000000000001'), 'gm', 'quem cria a campanha é o mestre (gm)');

select matches(public.set_campaign_invite('c0000000-0000-0000-0000-000000000001'), '^[A-HJ-NP-Z2-9]{6}$', 'código aleatório: 6 caracteres sem 0/O, 1/I');
select throws_ok($$select public.set_campaign_invite('c0000000-0000-0000-0000-000000000001', 'Dragões!')$$, '22023', 'invalid_code', 'código escolhido só com letras sem acento, algarismos e hífen');
select is(public.set_campaign_invite('c0000000-0000-0000-0000-000000000001', ' mesa-de-sexta '), 'MESA-DE-SEXTA', 'o mestre escolhe o código (vira maiúsculas)');
select is((select count(*)::int from public.campaign_invite), 1, 'um código por campanha (o novo troca o anterior)');
select throws_ok($$select public.set_campaign_invite('c0000000-0000-0000-0000-000000000002', 'Mesa-De-Sexta')$$, '23505', 'code_in_use', 'código em uso em outra campanha (sem diferenciar maiúsculas)');

-- Jogador: antes de entrar, não vê nada; entra com o código.
select set_config('request.jwt.claims', '{"sub":"88888888-8888-8888-8888-888888888888","role":"authenticated"}', true);
select is((select count(*)::int from public.campaign), 0, 'antes de entrar, o jogador não vê a campanha');
select throws_ok($$select public.join_campaign('ERRADO')$$, 'P0002', 'invalid_invite', 'código errado não entra');
select is(public.join_campaign('mesa-de-sexta', 'Ana'), 'c0000000-0000-0000-0000-000000000001'::uuid, 'entra com o código, sem diferenciar maiúsculas');
select is((select count(*)::int from public.campaign), 1, 'o jogador lê a campanha em que entrou (só ela)');
select is((select count(*)::int from public.campaign_member), 2, 'e vê os membros: mestre e ele');
select is((select display_name from public.campaign_member where role = 'player'), 'Ana', 'com o nome que informou');
select is((select count(*)::int from public.campaign_invite), 0, 'o jogador não vê o código');
select throws_ok($$select public.set_campaign_invite('c0000000-0000-0000-0000-000000000001')$$, '42501', 'not_gm', 'só o mestre mexe no convite');
update public.campaign set name = 'Hack' where id = 'c0000000-0000-0000-0000-000000000001';
insert into public.session (id, campaign_id, date) values ('5e000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', now());
select is((select count(*)::int from public.session), 1, 'o jogador cria sessão na campanha');

-- Alguém de fora: não vê nem cria nada na campanha.
select set_config('request.jwt.claims', '{"sub":"99999999-9999-9999-9999-999999999999","role":"authenticated"}', true);
select is((select count(*)::int from public.session), 0, 'quem é de fora não vê as sessões');
select throws_ok(
  $$insert into public.session (id, campaign_id, date) values ('5e000000-0000-0000-0000-000000000002', 'c0000000-0000-0000-0000-000000000001', now())$$,
  '42501', null, 'quem é de fora não cria sessão');

-- Mestre: o nome continua o dele (o jogador não edita a campanha); remove o jogador.
select set_config('request.jwt.claims', '{"sub":"77777777-7777-7777-7777-777777777777","role":"authenticated"}', true);
select is((select name from public.campaign where id = 'c0000000-0000-0000-0000-000000000001'), 'Sigil', 'o jogador não edita a campanha');
select lives_ok($$select public.remove_campaign_member('c0000000-0000-0000-0000-000000000001', '88888888-8888-8888-8888-888888888888')$$, 'o mestre remove o jogador');
select set_config('request.jwt.claims', '{"sub":"88888888-8888-8888-8888-888888888888","role":"authenticated"}', true);
select is((select count(*)::int from public.campaign), 0, 'removido, não vê mais a campanha');

-- Entra de novo; o mestre apaga a campanha (marcação) e os jogadores saem.
select public.join_campaign('MESA-DE-SEXTA');
select set_config('request.jwt.claims', '{"sub":"77777777-7777-7777-7777-777777777777","role":"authenticated"}', true);
update public.campaign set deleted_at = now() where id = 'c0000000-0000-0000-0000-000000000001';
-- (direto na tabela: pelo RLS, a campanha apagada já não aparece para ninguém)
reset role;
select is((select count(*)::int from public.campaign_member where campaign_id = 'c0000000-0000-0000-0000-000000000001' and role = 'player'), 0, 'campanha apagada: os jogadores saem');
select is((select count(*)::int from public.campaign_invite where campaign_id = 'c0000000-0000-0000-0000-000000000001'), 0, 'e o convite deixa de valer');
set local role authenticated;

-- Revogar: o código para de funcionar.
select public.set_campaign_invite('c0000000-0000-0000-0000-000000000002', 'OUTRA-MESA');
select public.revoke_campaign_invite('c0000000-0000-0000-0000-000000000002');
select set_config('request.jwt.claims', '{"sub":"88888888-8888-8888-8888-888888888888","role":"authenticated"}', true);
select throws_ok($$select public.join_campaign('OUTRA-MESA')$$, 'P0002', 'invalid_invite', 'código revogado não entra');

reset role;
select * from finish();
rollback;
