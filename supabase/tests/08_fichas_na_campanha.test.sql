-- Fase 2b (2026-10-13): o jogador põe a ficha na campanha; o mestre lê e edita
-- a ficha e as folhas; só o dono apaga ou tira da campanha; o dono não muda;
-- os arquivos da ficha seguem a ficha; outro jogador não vê; remover o jogador
-- devolve a ficha ao Sandbox.
begin;
create extension if not exists pgtap with schema extensions;
select plan(17);

insert into auth.users (id, email, aud, role) values
  ('bbbbbbbb-0000-0000-0000-000000000001', 'mestre3@teste.dev', 'authenticated', 'authenticated'),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'jogadora3@teste.dev', 'authenticated', 'authenticated'),
  ('bbbbbbbb-0000-0000-0000-000000000003', 'outro3@teste.dev', 'authenticated', 'authenticated');

set local role authenticated;

-- Mestre: campanha com convite.
select set_config('request.jwt.claims', '{"sub":"bbbbbbbb-0000-0000-0000-000000000001","role":"authenticated"}', true);
insert into public.campaign (id, name) values ('c2000000-0000-0000-0000-000000000001', 'Mesa B');
select public.set_campaign_invite('c2000000-0000-0000-0000-000000000001', 'MESA-FICHAS');

-- Quem não é membro não põe ficha na campanha.
select set_config('request.jwt.claims', '{"sub":"bbbbbbbb-0000-0000-0000-000000000003","role":"authenticated"}', true);
select throws_ok(
  $$insert into public.character (id, campaign_id, data) values ('cc000000-0000-0000-0000-000000000009', 'c2000000-0000-0000-0000-000000000001', '{"name":"Intruso"}')$$,
  '42501', null, 'quem não é membro não põe ficha na campanha');

-- Jogadora: entra, cria a ficha no Sandbox (com retrato) e põe na campanha.
select set_config('request.jwt.claims', '{"sub":"bbbbbbbb-0000-0000-0000-000000000002","role":"authenticated"}', true);
select public.join_campaign('MESA-FICHAS', 'Lia');
insert into public.attachment (id, sha256, mime, bytes, storage_path)
  values ('a7000000-0000-0000-0000-000000000001', 'abc', 'image/jpeg', 10, 'bbbbbbbb-0000-0000-0000-000000000002/abc');
insert into public.character (id, campaign_id, portrait_attachment, data)
  values ('cc000000-0000-0000-0000-000000000001', null, 'a7000000-0000-0000-0000-000000000001', '{"name":"Lia, a Ladra","level":3}');
update public.character set campaign_id = 'c2000000-0000-0000-0000-000000000001', version = 1 where id = 'cc000000-0000-0000-0000-000000000001';
select is((select campaign_id from public.character where id = 'cc000000-0000-0000-0000-000000000001'), 'c2000000-0000-0000-0000-000000000001'::uuid, 'a jogadora põe a ficha na campanha em que entrou');

-- Mestre: lê, edita, cria folha; não apaga, não tira da campanha, não troca o dono.
select set_config('request.jwt.claims', '{"sub":"bbbbbbbb-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is((select name from public.character where id = 'cc000000-0000-0000-0000-000000000001'), 'Lia, a Ladra', 'o mestre lê a ficha da jogadora');
update public.character set data = '{"name":"Lia, a Ladra","level":4}', version = 2 where id = 'cc000000-0000-0000-0000-000000000001';
select is((select level from public.character where id = 'cc000000-0000-0000-0000-000000000001'), 4, 'o mestre edita a ficha');
select ok((select conflicted_at is null from public.character where id = 'cc000000-0000-0000-0000-000000000001'), 'com a versão certa, sem conflito');
insert into public.spell_sheet (id, character_id, data) values ('55000000-0000-0000-0000-000000000001', 'cc000000-0000-0000-0000-000000000001', '{"title":"Dia 1"}');
select is((select owner_id from public.spell_sheet where id = '55000000-0000-0000-0000-000000000001'), 'bbbbbbbb-0000-0000-0000-000000000002'::uuid, 'a folha que o mestre cria fica no nome da dona da ficha');
select throws_ok(
  $$update public.character set deleted_at = now() where id = 'cc000000-0000-0000-0000-000000000001'$$,
  '42501', 'owner_only', 'o mestre não apaga a ficha');
select throws_ok(
  $$update public.character set campaign_id = null where id = 'cc000000-0000-0000-0000-000000000001'$$,
  '42501', null, 'o mestre não tira a ficha da campanha');
select throws_ok(
  $$update public.character set owner_id = 'bbbbbbbb-0000-0000-0000-000000000001' where id = 'cc000000-0000-0000-0000-000000000001'$$,
  '42501', 'owner_fixed', 'ninguém troca o dono');
select is((select count(*)::int from public.attachment where id = 'a7000000-0000-0000-0000-000000000001'), 1, 'o mestre lê o registro do retrato');
select ok(public.can_read_attachment('a7000000-0000-0000-0000-000000000001'), 'e o arquivo do retrato');
select is((select count(*)::int from public.notebook_entry), 0, 'o caderno continua só do autor');

-- Outro jogador da mesma campanha não vê a ficha (o resumo do grupo é a Fase 2c).
select set_config('request.jwt.claims', '{"sub":"bbbbbbbb-0000-0000-0000-000000000003","role":"authenticated"}', true);
select public.join_campaign('MESA-FICHAS', 'Rui');
select is((select count(*)::int from public.character), 0, 'outro jogador não vê a ficha');
select is((select count(*)::int from public.spell_sheet), 0, 'nem a folha');
select ok(not public.can_read_attachment('a7000000-0000-0000-0000-000000000001'), 'nem o retrato');

-- Mestre remove a jogadora: a ficha volta ao Sandbox dela e o mestre deixa de ver.
select set_config('request.jwt.claims', '{"sub":"bbbbbbbb-0000-0000-0000-000000000001","role":"authenticated"}', true);
select public.remove_campaign_member('c2000000-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000002');
select is((select count(*)::int from public.character), 0, 'removida a jogadora, o mestre não vê mais a ficha');
reset role;
select is((select campaign_id from public.character where id = 'cc000000-0000-0000-0000-000000000001'), null, 'a ficha voltou ao Sandbox');

select * from finish();
rollback;
