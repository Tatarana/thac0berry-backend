-- Sessão (2026-10-13): só quem criou, ou o mestre, edita, fecha e apaga; os
-- outros membros leem e criam as suas.
begin;
create extension if not exists pgtap with schema extensions;
select plan(4);

insert into auth.users (id, email, aud, role) values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'mestre2@teste.dev', 'authenticated', 'authenticated'),
  ('aaaaaaaa-0000-0000-0000-000000000002', 'jogador2@teste.dev', 'authenticated', 'authenticated');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-000000000001","role":"authenticated"}', true);
insert into public.campaign (id, name) values ('c1000000-0000-0000-0000-000000000001', 'Mesa');
select public.set_campaign_invite('c1000000-0000-0000-0000-000000000001', 'MESA-SESSOES');
insert into public.session (id, campaign_id, date, title) values ('5e100000-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000001', now(), 'do mestre');

select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-000000000002","role":"authenticated"}', true);
select public.join_campaign('MESA-SESSOES', 'Bia');
update public.session set title = 'mexi', is_archived = true, deleted_at = now() where id = '5e100000-0000-0000-0000-000000000001';
insert into public.session (id, campaign_id, date, title) values ('5e100000-0000-0000-0000-000000000002', 'c1000000-0000-0000-0000-000000000001', now(), 'da Bia');
update public.session set is_archived = true where id = '5e100000-0000-0000-0000-000000000002';
select is((select is_archived from public.session where id = '5e100000-0000-0000-0000-000000000002'), true, 'quem criou fecha a própria sessão');

select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is((select title from public.session where id = '5e100000-0000-0000-0000-000000000001'), 'do mestre', 'o jogador não edita a sessão do mestre');
select ok((select deleted_at is null and not is_archived from public.session where id = '5e100000-0000-0000-0000-000000000001'), 'nem fecha nem apaga');
update public.session set summary = 'o mestre anotou' where id = '5e100000-0000-0000-0000-000000000002';
select is((select summary from public.session where id = '5e100000-0000-0000-0000-000000000002'), 'o mestre anotou', 'o mestre edita a sessão do jogador');

reset role;
select * from finish();
rollback;
