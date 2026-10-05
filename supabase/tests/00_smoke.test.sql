-- Teste de fumaça: o banco local sobe e o pgTAP funciona. Os testes de
-- permissão de verdade (ex.: "jogador não lê o caderno de outro") entram junto
-- com cada migração.
begin;
create extension if not exists pgtap with schema extensions;
select plan(1);
select has_schema('public', 'schema public existe');
select * from finish();
rollback;
