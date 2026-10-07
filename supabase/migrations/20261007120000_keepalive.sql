-- Manter o projeto ativo (2026-10-07).
-- No plano gratuito, o Supabase pausa o projeto que fica uma semana sem
-- atividade de banco. A Action .github/workflows/keepalive.yml chama esta
-- função uma vez por dia com a chave pública. Ela não lê nenhuma tabela e não
-- expõe dado nenhum: só devolve a hora do servidor.

create function public.keepalive()
returns timestamptz
language sql
stable
set search_path = ''
as $$ select now() $$;

-- A migração de acesso explícito revoga tudo por padrão; esta é a única função
-- liberada para quem não está logado.
grant execute on function public.keepalive() to anon, authenticated;
