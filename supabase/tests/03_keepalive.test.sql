-- keepalive(): chamada pela Action diária, sem login; não dá acesso a dados.
begin;
create extension if not exists pgtap with schema extensions;
select plan(3);

set local role anon;
select isnt(public.keepalive(), null, 'anônimo chama keepalive()');
select throws_ok($$ select count(*) from public.character $$, '42501', null, 'anônimo continua sem acesso a personagens');

reset role;
set local role authenticated;
select isnt(public.keepalive(), null, 'logado também chama keepalive()');

select * from finish();
rollback;
