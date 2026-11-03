-- Perfil Admin e imagens do site versionadas (2026-11-03): qualquer um lê,
-- inclusive sem login; só o admin (e-mail confirmado da lista) envia arquivo,
-- registra versão e troca a atual; nada é apagado.
begin;
create extension if not exists pgtap with schema extensions;
select plan(17);

insert into auth.users (id, email, email_confirmed_at, aud, role) values
  ('ad000000-0000-0000-0000-000000000001', 'fernando.hreis@gmail.com', now(), 'authenticated', 'authenticated'),
  ('ad000000-0000-0000-0000-000000000002', 'jog8@teste.dev', now(), 'authenticated', 'authenticated');

select has_table('public', 'site_image_version', 'tabela das versões das imagens do site');
select ok((select public from storage.buckets where id = 'site-images'), 'o bucket site-images é público');

set local role authenticated;

-- Um jogador comum: não é admin, não envia arquivo, não registra versão.
select set_config('request.jwt.claims', '{"sub":"ad000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
select ok(not public.is_admin(), 'o jogador não é admin');
select throws_ok(
  $$insert into storage.objects (bucket_id, name) values ('site-images', 'forge/race-dwarf-male/hack.webp')$$,
  '42501', null, 'o jogador não envia arquivo ao bucket');
select throws_ok(
  $$select public.add_site_image_version('forge/race-dwarf-male', 'forge/race-dwarf-male/hack.webp')$$,
  '42501', null, 'nem registra versão');
select throws_ok(
  $$insert into public.site_image_version (slot, version, storage_path) values ('forge/x', 1, 'forge/x/a.webp')$$,
  '42501', null, 'nem grava direto na tabela');

-- O admin envia duas versões; a última é a atual.
select set_config('request.jwt.claims', '{"sub":"ad000000-0000-0000-0000-000000000001","role":"authenticated","email":"fernando.hreis@gmail.com"}', true);
select ok(public.is_admin(), 'o admin é admin');
insert into storage.objects (bucket_id, name) values
  ('site-images', 'forge/race-dwarf-male/a.webp'),
  ('site-images', 'forge/race-dwarf-male/b.webp');
select is(public.add_site_image_version('forge/race-dwarf-male', 'forge/race-dwarf-male/a.webp', 896, 1200), 1, 'primeira versão é a 1');
select is(public.add_site_image_version('forge/race-dwarf-male', 'forge/race-dwarf-male/b.webp', 896, 1200), 2, 'a seguinte é a 2');
select is((select version from public.site_image_version where slot = 'forge/race-dwarf-male' and is_current), 2, 'a 2 é a atual');
select throws_ok(
  $$select public.add_site_image_version('forge/race-elf-male', 'forge/race-dwarf-male/a.webp')$$,
  '22023', null, 'o arquivo tem de estar na pasta do slot');
select throws_ok(
  $$select public.add_site_image_version('forge/race-dwarf-male', 'forge/race-dwarf-male/nao-enviado.webp')$$,
  'P0002', null, 'só registra arquivo que está no bucket');

-- Volta para a 1.
select public.set_current_site_image('forge/race-dwarf-male', 1);
select is((select array_agg(version order by version) from public.site_image_version where slot = 'forge/race-dwarf-male' and is_current), array[1], 'a 1 volta a ser a única atual');

-- O jogador não troca a atual.
select set_config('request.jwt.claims', '{"sub":"ad000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
select throws_ok(
  $$select public.set_current_site_image('forge/race-dwarf-male', 2)$$,
  '42501', null, 'o jogador não troca a versão atual');

-- Sem login: lê as versões e os arquivos.
reset role;
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select is((select count(*)::int from public.site_image_version where slot = 'forge/race-dwarf-male'), 2, 'sem login lê as versões');
select is((select count(*)::int from storage.objects where bucket_id = 'site-images'), 2, 'e os arquivos do bucket');

-- Ninguém apaga.
reset role;
select is((select count(*)::int from information_schema.role_table_grants
  where table_name = 'site_image_version' and grantee in ('anon', 'authenticated') and privilege_type in ('INSERT', 'UPDATE', 'DELETE')), 0,
  'pela API só se lê a tabela (gravar só pelas funções; apagar, nunca)');

select * from finish();
rollback;
