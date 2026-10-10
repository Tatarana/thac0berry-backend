-- Preferências da conta (Settings da web, 2026-10-10): papel padrão do caderno
-- e nome padrão do jogador; só o próprio usuário lê e grava.
begin;
create extension if not exists pgtap with schema extensions;
select plan(5);

insert into auth.users (id, email, aud, role) values
  ('33333333-3333-3333-3333-333333333333', 'c@teste.dev', 'authenticated', 'authenticated'),
  ('44444444-4444-4444-4444-444444444444', 'd@teste.dev', 'authenticated', 'authenticated');

select has_column('public', 'user_preferences', 'default_player_name', 'coluna do nome padrão do jogador');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true);
insert into public.user_preferences (default_notebook_paper_style, default_player_name) values ('lined', 'Fernando');
select is((select default_player_name from public.user_preferences), 'Fernando', 'o dono grava o nome padrão');

update public.user_preferences set default_notebook_paper_style = 'grid', version = version;
select is((select default_notebook_paper_style from public.user_preferences), 'grid', 'o dono troca o papel padrão');

select set_config('request.jwt.claims', '{"sub":"44444444-4444-4444-4444-444444444444","role":"authenticated"}', true);
select is((select count(*)::int from public.user_preferences), 0, 'outro usuário não vê as preferências');
update public.user_preferences set default_player_name = 'Outro';
reset role;
select is((select default_player_name from public.user_preferences where user_id = '33333333-3333-3333-3333-333333333333'), 'Fernando', 'outro usuário não altera');

select * from finish();
rollback;
