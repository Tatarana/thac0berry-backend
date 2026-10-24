-- Itens mágicos criados pelo mestre ou pelo jogador (2026-10-24): o dono lê e
-- edita; o mestre da campanha lê os privados dos jogadores dela; os membros
-- leem os compartilhados com a campanha; quem é de fora não vê nada.
begin;
create extension if not exists pgtap with schema extensions;
select plan(14);

insert into auth.users (id, email, aud, role) values
  ('ab000000-0000-0000-0000-000000000001', 'mestre7@teste.dev', 'authenticated', 'authenticated'),
  ('ab000000-0000-0000-0000-000000000002', 'jog7a@teste.dev', 'authenticated', 'authenticated'),
  ('ab000000-0000-0000-0000-000000000003', 'jog7b@teste.dev', 'authenticated', 'authenticated'),
  ('ab000000-0000-0000-0000-000000000004', 'fora7@teste.dev', 'authenticated', 'authenticated');

select has_table('public', 'custom_magic_item', 'tabela dos itens mágicos criados');

set local role authenticated;

-- O mestre cria a campanha, um item compartilhado e um secreto.
select set_config('request.jwt.claims', '{"sub":"ab000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
insert into public.campaign (id, name) values ('c7000000-0000-0000-0000-000000000001', 'Mesa I');
select public.set_campaign_invite('c7000000-0000-0000-0000-000000000001', 'MESA-ITENS');
insert into public.custom_magic_item (id, campaign_id, visibility, data)
  values ('1a000000-0000-0000-0000-000000000001', 'c7000000-0000-0000-0000-000000000001', 'campaign', '{"name":"Kelmon''s Blade +2"}');
insert into public.custom_magic_item (id, campaign_id, visibility, data)
  values ('1a000000-0000-0000-0000-000000000002', 'c7000000-0000-0000-0000-000000000001', 'private', '{"name":"Cursed Mirror"}');
select is((select name from public.custom_magic_item where id = '1a000000-0000-0000-0000-000000000001'), 'Kelmon''s Blade +2', 'nome tirado do data');
select throws_ok(
  $$insert into public.custom_magic_item (id, campaign_id, visibility, data) values ('1a000000-0000-0000-0000-000000000009', null, 'campaign', '{"name":"x"}')$$,
  '23514', null, 'compartilhar com a campanha exige uma campanha');

-- A jogadora A entra, vê o compartilhado e não o secreto; cria um privado e o compartilha.
select set_config('request.jwt.claims', '{"sub":"ab000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
select public.join_campaign('MESA-ITENS', 'Iara');
select is((select array_agg(name order by name) from public.custom_magic_item), array['Kelmon''s Blade +2'], 'a jogadora vê o item compartilhado, não o secreto do mestre');
insert into public.custom_magic_item (id, campaign_id, visibility, data)
  values ('1a000000-0000-0000-0000-000000000003', 'c7000000-0000-0000-0000-000000000001', 'private', '{"name":"Iara''s Charm"}');
insert into public.custom_magic_item (id, campaign_id, data)
  values ('1a000000-0000-0000-0000-000000000004', null, '{"name":"Sandbox Trinket"}');
update public.custom_magic_item set data = '{"name":"hack"}', version = 1 where id = '1a000000-0000-0000-0000-000000000001';
select is((select name from public.custom_magic_item where id = '1a000000-0000-0000-0000-000000000001'), 'Kelmon''s Blade +2', 'a jogadora não edita o item do mestre');

-- A jogadora B: não vê o privado de A.
select set_config('request.jwt.claims', '{"sub":"ab000000-0000-0000-0000-000000000003","role":"authenticated"}', true);
select public.join_campaign('MESA-ITENS', 'Bo');
select is((select count(*)::int from public.custom_magic_item where id = '1a000000-0000-0000-0000-000000000003'), 0, 'outra jogadora não vê o item privado de A');

-- O mestre vê o privado de A na campanha, mas não o pessoal (sem campanha) dela.
select set_config('request.jwt.claims', '{"sub":"ab000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is((select count(*)::int from public.custom_magic_item where id = '1a000000-0000-0000-0000-000000000003'), 1, 'o mestre vê o item privado da jogadora na campanha');
select is((select count(*)::int from public.custom_magic_item where id = '1a000000-0000-0000-0000-000000000004'), 0, 'mas não o item pessoal dela, sem campanha');
update public.custom_magic_item set data = '{"name":"hack"}', version = 1 where id = '1a000000-0000-0000-0000-000000000003';

-- A jogadora A compartilha o dela; B passa a ver. A edição do mestre não pegou.
select set_config('request.jwt.claims', '{"sub":"ab000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
select is((select name from public.custom_magic_item where id = '1a000000-0000-0000-0000-000000000003'), 'Iara''s Charm', 'o mestre lê, mas não edita o item da jogadora');
update public.custom_magic_item set visibility = 'campaign', version = 1 where id = '1a000000-0000-0000-0000-000000000003';
select ok((select version = 2 and conflicted_at is null from public.custom_magic_item where id = '1a000000-0000-0000-0000-000000000003'), 'a dona compartilha com a versão certa');
select set_config('request.jwt.claims', '{"sub":"ab000000-0000-0000-0000-000000000003","role":"authenticated"}', true);
select is((select count(*)::int from public.custom_magic_item where id = '1a000000-0000-0000-0000-000000000003'), 1, 'a outra jogadora vê o item compartilhado');

-- Quem é de fora: não vê nada e não cria na campanha.
select set_config('request.jwt.claims', '{"sub":"ab000000-0000-0000-0000-000000000004","role":"authenticated"}', true);
select is((select count(*)::int from public.custom_magic_item), 0, 'quem não é da campanha não vê nada');
select throws_ok(
  $$insert into public.custom_magic_item (id, campaign_id, data) values ('1a000000-0000-0000-0000-000000000005', 'c7000000-0000-0000-0000-000000000001', '{"name":"x"}')$$,
  '42501', null, 'nem cria item na campanha');

reset role;
select is((select count(*)::int from information_schema.role_table_grants where table_name = 'custom_magic_item' and grantee = 'authenticated' and privilege_type = 'DELETE'), 0, 'ninguém apaga a linha (exclusão marcada)');

select * from finish();
rollback;
