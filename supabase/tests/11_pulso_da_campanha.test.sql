-- Fase 3, R2 (2026-10-14): o pulso da campanha muda quando muda uma ficha
-- (inclusive ao sair da campanha), uma sessão, um membro ou a campanha; só os
-- membros o leem, e ele está na publicação do Realtime.
begin;
create extension if not exists pgtap with schema extensions;
select plan(8);

insert into auth.users (id, email, aud, role) values
  ('eeeeeeee-0000-0000-0000-000000000001', 'mestre5@teste.dev', 'authenticated', 'authenticated'),
  ('eeeeeeee-0000-0000-0000-000000000002', 'jog5@teste.dev', 'authenticated', 'authenticated'),
  ('eeeeeeee-0000-0000-0000-000000000003', 'fora5@teste.dev', 'authenticated', 'authenticated');

select ok(exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'campaign_pulse'),
  'o pulso está na publicação do Realtime');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"eeeeeeee-0000-0000-0000-000000000001","role":"authenticated"}', true);
insert into public.campaign (id, name) values ('c5000000-0000-0000-0000-000000000001', 'Mesa P');
select public.set_campaign_invite('c5000000-0000-0000-0000-000000000001', 'MESA-PULSO');
select is((select count(*)::int from public.campaign_pulse), 1, 'criar a campanha (o mestre entra como membro) já pulsa');

-- Marca o pulso no passado para ver cada mudança.
reset role;
update public.campaign_pulse set changed_at = now() - interval '1 hour';
set local role authenticated;

select set_config('request.jwt.claims', '{"sub":"eeeeeeee-0000-0000-0000-000000000002","role":"authenticated"}', true);
select public.join_campaign('MESA-PULSO', 'Bea');
select ok((select changed_at > now() - interval '1 minute' from public.campaign_pulse), 'um jogador entrar pulsa (e ele lê o pulso)');

reset role;
update public.campaign_pulse set changed_at = now() - interval '1 hour';
set local role authenticated;
insert into public.character (id, campaign_id, data) values ('ce000000-0000-0000-0000-000000000001', 'c5000000-0000-0000-0000-000000000001', '{"name":"Bea","hitPointsCurrent":8,"hitPointsMax":8}');
select ok((select changed_at > now() - interval '1 minute' from public.campaign_pulse), 'ficha posta na campanha pulsa');

reset role;
update public.campaign_pulse set changed_at = now() - interval '1 hour';
set local role authenticated;
update public.character set data = '{"name":"Bea","hitPointsCurrent":3,"hitPointsMax":8}', version = 1 where id = 'ce000000-0000-0000-0000-000000000001';
select ok((select changed_at > now() - interval '1 minute' from public.campaign_pulse), 'PV mudados pulsam');

reset role;
update public.campaign_pulse set changed_at = now() - interval '1 hour';
set local role authenticated;
insert into public.session (id, campaign_id, date) values ('5f000000-0000-0000-0000-000000000001', 'c5000000-0000-0000-0000-000000000001', now());
select ok((select changed_at > now() - interval '1 minute' from public.campaign_pulse), 'sessão nova pulsa');

reset role;
update public.campaign_pulse set changed_at = now() - interval '1 hour';
set local role authenticated;
update public.character set campaign_id = null, version = 2 where id = 'ce000000-0000-0000-0000-000000000001';
select ok((select changed_at > now() - interval '1 minute' from public.campaign_pulse), 'ficha que sai da campanha pulsa a campanha antiga');

select set_config('request.jwt.claims', '{"sub":"eeeeeeee-0000-0000-0000-000000000003","role":"authenticated"}', true);
select is((select count(*)::int from public.campaign_pulse), 0, 'quem é de fora não lê o pulso');

reset role;
select * from finish();
rollback;
