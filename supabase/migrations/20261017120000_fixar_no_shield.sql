-- Fixar no Shield (2026-10-17; web "DM Shield", opção A): o mestre fixa
-- tabelas, monstros ou fichas de PC/NPC na campanha ativa, para acesso rápido
-- em DM Tools. Decisão do usuário: lista por campanha (não existe no
-- One-shot, que não tem linha de campanha).
--
-- `pinned_items`: array de {kind, ref_id, label} — "kind" é "table", "monster"
-- ou "character"; "ref_id" é o id do item (tabela de livro, do mestre ou
-- monstro) ou o uuid do personagem; "label" é o texto do chip, gravado junto
-- para não precisar buscar os dados de novo. Mesma permissão de sempre da
-- `campaign` (o mestre dela lê e grava); contrato de sempre (version/trigger).

alter table public.campaign
  add column pinned_items jsonb not null default '[]'::jsonb;
