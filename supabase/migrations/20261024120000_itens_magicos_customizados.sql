-- Itens mágicos criados pelo mestre ou pelo jogador (2026-10-24; proposta
-- aprovada na conversa, decisões do usuário):
-- - de uma campanha (o mestre ou um jogador dela) ou pessoais (sem campanha);
-- - `visibility`: 'private' (só o dono) ou 'campaign' (os membros da campanha
--   leem); o jogador também pode compartilhar com a campanha;
-- - o mestre da campanha lê também os itens privados dos jogadores dela (como
--   lê as fichas, Fase 2b);
-- - só o dono edita; ninguém apaga a linha (exclusão em `deleted_at`).
--
-- `data` segue um subconjunto de schemas/magic-item.schema.json do
-- thac0berry-data (nome, classificação, descrição, valor, bônus), para a web
-- mostrar com a mesma ficha dos itens do livro. A ficha do personagem guarda
-- uma cópia curta (nome, resumo, bônus) com o id e a versão do item, e se
-- atualiza quando quem pode editar a ficha a abre e o item mudou.
-- Mesmo contrato das outras tabelas: INSERT para novo, UPDATE com `version`
-- (nunca upsert); conflito marcado.
create table public.custom_magic_item (
  id             uuid primary key,
  owner_id       uuid not null default auth.uid() references auth.users on delete cascade,
  campaign_id    uuid references public.campaign,           -- null = pessoal (sem campanha)
  visibility     text not null default 'private' check (visibility in ('private', 'campaign')),
  data           jsonb not null,
  name           text generated always as (data ->> 'name') stored,
  version        bigint      not null default 1,
  updated_at     timestamptz not null default now(),
  updated_by     uuid,
  change_seq     bigint      not null default nextval('public.sync_change_seq'),
  deleted_at     timestamptz,
  schema_version int         not null default 1,
  conflicted_at  timestamptz,
  -- Compartilhar com a campanha exige uma campanha.
  constraint custom_magic_item_campaign_visibility check (visibility = 'private' or campaign_id is not null)
);
create index custom_magic_item_owner_seq_idx on public.custom_magic_item (owner_id, change_seq);
create index custom_magic_item_campaign_idx  on public.custom_magic_item (campaign_id);
create trigger sync_before_write before insert or update on public.custom_magic_item
  for each row execute function public.sync_before_write();
alter table public.custom_magic_item enable row level security;

-- Lê: o dono; o mestre da campanha (privados dos jogadores inclusive); os
-- membros da campanha quando o item foi compartilhado.
create policy "dono, mestre e campanha leem" on public.custom_magic_item for select to authenticated
  using (
    owner_id = (select auth.uid())
    or (campaign_id is not null and (
      public.is_campaign_gm(campaign_id)
      or (visibility = 'campaign' and public.is_campaign_member(campaign_id)))));

-- Cria e edita: só o dono, numa campanha de que é membro (mestre ou jogador) ou sem campanha.
create policy "dono cria" on public.custom_magic_item for insert to authenticated
  with check (owner_id = (select auth.uid()) and (campaign_id is null or public.is_campaign_member(campaign_id)));
create policy "dono edita" on public.custom_magic_item for update to authenticated
  using (owner_id = (select auth.uid()))
  with check (owner_id = (select auth.uid()) and (campaign_id is null or public.is_campaign_member(campaign_id)));

grant select, insert, update on public.custom_magic_item to authenticated;
