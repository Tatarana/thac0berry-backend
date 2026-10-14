-- GT5: tabelas criadas pelo mestre (2026-10-14; web docs/grimorio-de-tabelas.md,
-- decisão 1 de 2026-10-08: "tabelas criadas pelo mestre, entrega própria").
--
-- Decisões do usuário:
-- - só do mestre (os jogadores não veem);
-- - de uma campanha (a ativa do modo DM), ou sem campanha (One-shot), com a
--   opção de copiar para outra campanha (cópia independente);
-- - pode começar copiando uma tabela de livro.
--
-- `data` é a tabela como a web a mostra e rola: {title, dice, headers, rows,
-- notes, source}. Mesmo contrato das outras tabelas: INSERT para nova, UPDATE com
-- `version` (nunca upsert); conflito marcado; exclusão em `deleted_at`.

create table public.dm_table (
  id             uuid primary key,
  owner_id       uuid not null default auth.uid() references auth.users on delete cascade,
  campaign_id    uuid references public.campaign,           -- null = One-shot
  data           jsonb not null,
  name           text generated always as (data ->> 'title') stored,
  version        bigint      not null default 1,
  updated_at     timestamptz not null default now(),
  updated_by     uuid,
  change_seq     bigint      not null default nextval('public.sync_change_seq'),
  deleted_at     timestamptz,
  schema_version int         not null default 1,
  conflicted_at  timestamptz
);

create index dm_table_owner_seq_idx on public.dm_table (owner_id, change_seq);
create index dm_table_campaign_idx  on public.dm_table (campaign_id);

create trigger sync_before_write before insert or update on public.dm_table
  for each row execute function public.sync_before_write();

alter table public.dm_table enable row level security;

-- Só o mestre que criou; a campanha, se houver, também é dele.
create policy "dono lê" on public.dm_table for select to authenticated
  using (owner_id = (select auth.uid()));
create policy "dono cria" on public.dm_table for insert to authenticated
  with check (owner_id = (select auth.uid()) and (campaign_id is null or exists (
    select 1 from public.campaign c where c.id = campaign_id and c.owner_id = (select auth.uid()))));
create policy "dono edita" on public.dm_table for update to authenticated
  using (owner_id = (select auth.uid()))
  with check (owner_id = (select auth.uid()) and (campaign_id is null or exists (
    select 1 from public.campaign c where c.id = campaign_id and c.owner_id = (select auth.uid()))));

grant select, insert, update on public.dm_table to authenticated;
