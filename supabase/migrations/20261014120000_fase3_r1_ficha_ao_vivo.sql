-- Fase 3, R1: ficha ao vivo (2026-10-14; docs/modelo-de-dados-e-sync.md §9).
--
-- A ficha e as folhas de magia entram na publicação do Realtime do Supabase:
-- quem tem a ficha aberta é avisado quando outra pessoa (o mestre, quem tem
-- acesso temporário) ou outro aparelho grava. O Realtime respeita o RLS: cada
-- um só recebe avisos das linhas que já pode ler. A web, ao receber o aviso,
-- relê a linha pela API (o aviso só diz que mudou).
--
-- Decisões do usuário: sem edição pendente, a versão nova entra na hora com um
-- aviso; com edição pendente, a do aparelho é gravada por cima (a última vence,
-- a outra fica no histórico, com o aviso de conflito de sempre).

do $$
begin
  -- No Supabase a publicação já existe; num Postgres sem ela (testes), cria.
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
end;
$$;

alter publication supabase_realtime add table public.character, public.spell_sheet;
