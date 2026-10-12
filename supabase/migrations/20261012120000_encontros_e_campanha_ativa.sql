-- Encontros do Combat Tracker e campanha ativa do DM na conta (2026-10-12,
-- backlog item 4 da web; docs/modelo-de-dados-e-sync.md §3 e §4.1).
--
-- Decisões do usuário:
-- - os encontros e as configurações do Combat Tracker vão para a conta (todos os
--   aparelhos); sem login, a web continua guardando só no aparelho;
-- - uma só campanha ativa por conta (trocar num aparelho troca nos outros);
-- - mesmo encontro gravado em dois aparelhos: o contrato de sempre (UPDATE com
--   `version`; `conflicted_at` marca a gravação baseada em versão antiga, e a web
--   avisa e recarrega).

-- ---------------------------------------------------------------------------
-- Encontro: o JSON do `Encounter` da web (src/rules/combat.ts) em `data`.
-- `campaign_id` nulo = One-shot (jogo sem campanha).
-- ---------------------------------------------------------------------------

create table public.encounter (
  id             uuid primary key,
  owner_id       uuid not null default auth.uid() references auth.users on delete cascade,
  campaign_id    uuid references public.campaign,
  data           jsonb not null,
  name           text generated always as (data ->> 'name') stored,
  ended          boolean generated always as ((data ->> 'endedAt') is not null) stored,
  version        bigint      not null default 1,
  updated_at     timestamptz not null default now(),
  updated_by     uuid,
  change_seq     bigint      not null default nextval('public.sync_change_seq'),
  deleted_at     timestamptz,
  schema_version int         not null default 1,
  conflicted_at  timestamptz
);

create index encounter_owner_seq_idx on public.encounter (owner_id, change_seq);
create index encounter_campaign_idx  on public.encounter (campaign_id);

create trigger sync_before_write before insert or update on public.encounter
  for each row execute function public.sync_before_write();

alter table public.encounter enable row level security;

-- Encontro: do dono (o DM); se tiver campanha, a campanha também é dele.
create policy "dono lê" on public.encounter for select to authenticated
  using (owner_id = (select auth.uid()));
create policy "dono cria" on public.encounter for insert to authenticated
  with check (owner_id = (select auth.uid()) and (campaign_id is null or exists (
    select 1 from public.campaign c where c.id = campaign_id and c.owner_id = (select auth.uid()))));
create policy "dono edita" on public.encounter for update to authenticated
  using (owner_id = (select auth.uid()))
  with check (owner_id = (select auth.uid()) and (campaign_id is null or exists (
    select 1 from public.campaign c where c.id = campaign_id and c.owner_id = (select auth.uid()))));

-- Acesso explícito (ver 20261005150000_acesso_explicito.sql): ler, criar e
-- editar; sem DELETE (exclusão é marcação em `deleted_at`).
grant select, insert, update on public.encounter to authenticated;

-- ---------------------------------------------------------------------------
-- Preferências: campanha ativa do DM e configurações do Combat Tracker.
-- ---------------------------------------------------------------------------

alter table public.user_preferences
  -- Campanha ativa do modo DM. Nula com `dm_active_one_shot` falso = ainda não
  -- escolheu; `dm_active_one_shot` verdadeiro = One-shot (sem campanha).
  add column dm_active_campaign_id uuid references public.campaign on delete set null,
  add column dm_active_one_shot boolean not null default false,
  -- Configurações do Combat Tracker (`CombatSettings` da web: iniciativa padrão,
  -- PV de monstro, morte em −10 ou 0, tabelas rápidas). Nulo = os padrões.
  add column combat_settings jsonb;
