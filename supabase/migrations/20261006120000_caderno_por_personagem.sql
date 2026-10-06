-- Caderno por personagem (2026-10-06).
-- Pedido do usuário: o caderno é do jogador, por personagem (cada personagem
-- de cada jogador tem o seu), e não da campanha. No app iPad isso é o formato
-- 2 do library.json (PlayerCharacter.notebookEntries).
--
-- - `character_id`: o personagem dono do caderno. Página nova sempre tem.
-- - `campaign_id` vira opcional: personagem do Sandbox também tem caderno.
-- - Páginas antigas (só com campanha) ficam como estão; o usuário decidiu
--   que, por ser beta, elas não precisam ser migradas.

alter table public.notebook_entry
  add column character_id uuid references public.character;

alter table public.notebook_entry
  alter column campaign_id drop not null;

create index notebook_entry_character_idx on public.notebook_entry (character_id);

-- Permissões: continua só o autor (Q3). Página nova precisa de um personagem
-- do autor; a campanha, se vier, também tem de ser dele.
drop policy "autor cria" on public.notebook_entry;
drop policy "autor edita" on public.notebook_entry;

create policy "autor cria" on public.notebook_entry for insert to authenticated
  with check (
    author_id = (select auth.uid())
    and exists (
      select 1 from public.character ch where ch.id = character_id and ch.owner_id = (select auth.uid()))
    and (campaign_id is null or exists (
      select 1 from public.campaign c where c.id = campaign_id and c.owner_id = (select auth.uid())))
  );

-- Editar (inclusive marcar `deleted_at`) vale também para as páginas antigas,
-- sem personagem.
create policy "autor edita" on public.notebook_entry for update to authenticated
  using (author_id = (select auth.uid()))
  with check (
    author_id = (select auth.uid())
    and (character_id is null or exists (
      select 1 from public.character ch where ch.id = character_id and ch.owner_id = (select auth.uid())))
    and (campaign_id is null or exists (
      select 1 from public.campaign c where c.id = campaign_id and c.owner_id = (select auth.uid())))
  );
