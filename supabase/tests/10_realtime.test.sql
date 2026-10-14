-- Fase 3 (2026-10-14): as tabelas que a web assina ao vivo estão na publicação
-- do Realtime (o RLS de leitura continua valendo para os avisos).
begin;
create extension if not exists pgtap with schema extensions;
select plan(2);

select ok(exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'character'),
  'a ficha está na publicação do Realtime');
select ok(exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'spell_sheet'),
  'as folhas de magia também');

select * from finish();
rollback;
