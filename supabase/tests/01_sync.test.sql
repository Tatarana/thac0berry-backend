-- Colunas de sincronização: versão, conflito, histórico, cursor.
begin;
create extension if not exists pgtap with schema extensions;
select plan(9);

insert into auth.users (id, email, aud, role)
values ('11111111-1111-1111-1111-111111111111', 'a@teste.dev', 'authenticated', 'authenticated');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);

-- O cliente tenta forjar as colunas de controle: o servidor ignora.
insert into public.campaign (id, name, version, change_seq, updated_by)
values ('c0000000-0000-0000-0000-000000000001', 'Elturel', 99, 999999, '22222222-2222-2222-2222-222222222222');

select is((select version from public.campaign where id = 'c0000000-0000-0000-0000-000000000001'),
          1::bigint, 'inserção nasce na versão 1 (versão do cliente ignorada)');
select isnt((select change_seq from public.campaign where id = 'c0000000-0000-0000-0000-000000000001'),
            999999::bigint, 'change_seq é do servidor');
select is((select updated_by from public.campaign where id = 'c0000000-0000-0000-0000-000000000001'),
          '11111111-1111-1111-1111-111111111111'::uuid, 'updated_by é quem gravou');

-- Atualização baseada na versão atual: sem conflito.
update public.campaign set name = 'Elturel II', version = 1
where id = 'c0000000-0000-0000-0000-000000000001';
select is((select version from public.campaign where id = 'c0000000-0000-0000-0000-000000000001'),
          2::bigint, 'atualização sobe a versão');
select is((select conflicted_at from public.campaign where id = 'c0000000-0000-0000-0000-000000000001'),
          null, 'baseada na versão atual: sem conflito');

-- Atualização baseada numa versão antiga (outro aparelho gravou antes):
-- aceita (a última vence), mas marcada como conflito.
update public.campaign set name = 'Elturel (iPad velho)', version = 1
where id = 'c0000000-0000-0000-0000-000000000001';
select is((select name from public.campaign where id = 'c0000000-0000-0000-0000-000000000001'),
          'Elturel (iPad velho)', 'a última gravação vence');
select isnt((select conflicted_at from public.campaign where id = 'c0000000-0000-0000-0000-000000000001'),
            null, 'versão-base antiga: marcada como conflito');

select throws_ok($$ select count(*) from public.record_history $$, '42501', null,
                 'histórico não é acessível pela API (sem GRANT)');

reset role;
select is((select count(*) from public.record_history
           where record_id = 'c0000000-0000-0000-0000-000000000001'),
          2::bigint, 'as duas versões substituídas ficaram no histórico');

select * from finish();
rollback;
