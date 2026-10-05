-- Fase 1: sincronização pessoal (um usuário, seus aparelhos e a web).
-- Desenho: docs/modelo-de-dados-e-sync.md. Sem compartilhamento ainda: toda
-- linha pertence ao usuário logado. A Fase 2 (mestre, membros, acesso
-- temporário) entra em migração própria, sem quebrar estas tabelas.

-- ---------------------------------------------------------------------------
-- Sincronização: sequência global e trigger comum
-- ---------------------------------------------------------------------------

-- Cursor do "o que mudou desde…": cada gravação aceita recebe o próximo número.
create sequence public.sync_change_seq;

-- Versões substituídas (regra "a última gravação vence, sem perder a anterior").
-- RLS ligado e SEM políticas: invisível para os clientes por enquanto; a leitura
-- e o "restaurar" entram junto com a tela do app (função própria).
create table public.record_history (
  table_name  text        not null,
  record_id   uuid        not null,
  version     bigint      not null,
  data        jsonb       not null,
  replaced_at timestamptz not null default now(),
  replaced_by uuid,
  primary key (table_name, record_id, version)
);
alter table public.record_history enable row level security;

-- Roda antes de todo INSERT/UPDATE das tabelas sincronizáveis.
-- Contrato do cliente: registro NOVO vai por INSERT (POST); registro que o
-- servidor já tem vai por UPDATE (PATCH ?id=eq.<id>) levando SEMPRE o `version`
-- conhecido. Não usar upsert (ON CONFLICT DO UPDATE): o trigger de INSERT roda
-- antes e zera a versão-base, e o conflito deixaria de ser detectado.
-- O cliente manda em `version` a versão em que se baseou. Se não for a atual,
-- a gravação é aceita mesmo assim (última vence), mas marcada em
-- `conflicted_at` para o app avisar. Colunas de controle são sempre do
-- servidor: o que o cliente mandar nelas é sobrescrito.
create function public.sync_before_write()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    new.version := 1;
    new.conflicted_at := null;
  else
    if new.version is distinct from old.version then
      new.conflicted_at := now();
    else
      new.conflicted_at := null;
    end if;
    insert into public.record_history (table_name, record_id, version, data, replaced_by)
    values (
      tg_table_name,
      coalesce(to_jsonb(old) ->> 'id', to_jsonb(old) ->> 'user_id')::uuid,
      old.version,
      to_jsonb(old),
      auth.uid()
    );
    new.version := old.version + 1;
  end if;
  new.updated_at := now();
  new.updated_by := auth.uid();
  new.change_seq := nextval('public.sync_change_seq');
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Tabelas. Todas têm as colunas de sincronização:
--   version, updated_at, updated_by, change_seq, deleted_at (exclusão marcada),
--   schema_version (formato do registro), conflicted_at.
-- Exclusão: o cliente NUNCA apaga linha (não há política de DELETE); marca
-- `deleted_at`, e a marcação chega aos outros aparelhos pelo pull.
-- Ordem de envio pelo cliente (por causa das chaves estrangeiras):
--   campaign → session → character → spell_sheet → notebook_entry.
-- ---------------------------------------------------------------------------

create table public.user_preferences (
  user_id                      uuid primary key default auth.uid() references auth.users on delete cascade,
  favorite_spell_ids           text[] not null default '{}',
  default_notebook_paper_style text,
  version        bigint      not null default 1,
  updated_at     timestamptz not null default now(),
  updated_by     uuid,
  change_seq     bigint      not null default nextval('public.sync_change_seq'),
  deleted_at     timestamptz,
  schema_version int         not null default 1,
  conflicted_at  timestamptz
);

create table public.attachment (
  id           uuid primary key default gen_random_uuid(),
  owner_id     uuid not null default auth.uid() references auth.users on delete cascade,
  sha256       text not null,
  mime         text not null,
  bytes        int  not null check (bytes >= 0),
  storage_path text not null,               -- <owner_id>/<sha256> no bucket "attachments"
  created_at   timestamptz not null default now(),
  unique (owner_id, sha256)
);

create table public.campaign (
  id               uuid primary key,
  owner_id         uuid not null default auth.uid() references auth.users on delete cascade,
  name             text not null default '',
  started_date     timestamptz,
  notes            text not null default '',
  is_archived      boolean not null default false,
  enabled_settings text[],                  -- null = todas as ambientações
  version        bigint      not null default 1,
  updated_at     timestamptz not null default now(),
  updated_by     uuid,
  change_seq     bigint      not null default nextval('public.sync_change_seq'),
  deleted_at     timestamptz,
  schema_version int         not null default 1,
  conflicted_at  timestamptz
);

create table public.session (
  id          uuid primary key,
  campaign_id uuid not null references public.campaign,
  owner_id    uuid not null default auth.uid() references auth.users on delete cascade,
  date        timestamptz not null,
  title       text not null default '',
  summary     text not null default '',
  is_archived boolean not null default false,
  version        bigint      not null default 1,
  updated_at     timestamptz not null default now(),
  updated_by     uuid,
  change_seq     bigint      not null default nextval('public.sync_change_seq'),
  deleted_at     timestamptz,
  schema_version int         not null default 1,
  conflicted_at  timestamptz
);

-- `data` = JSON do `PlayerCharacter` do app (Codable), sem `spellSheets` nem
-- `portraitImageData`. As colunas de resumo são CALCULADAS a partir dele:
-- o cliente não as grava, e elas nunca divergem da ficha.
create table public.character (
  id                  uuid primary key,
  owner_id            uuid not null default auth.uid() references auth.users on delete cascade,
  campaign_id         uuid references public.campaign,      -- null = Sandbox
  portrait_attachment uuid references public.attachment,
  data                jsonb not null,
  name            text generated always as (data ->> 'name') stored,
  character_class text generated always as (data ->> 'characterClass') stored,
  level           int  generated always as ((data ->> 'level')::int) stored,
  status          text generated always as (data ->> 'status') stored,
  version        bigint      not null default 1,
  updated_at     timestamptz not null default now(),
  updated_by     uuid,
  change_seq     bigint      not null default nextval('public.sync_change_seq'),
  deleted_at     timestamptz,
  schema_version int         not null default 1,
  conflicted_at  timestamptz
);

-- `data` = JSON do `SpellSheet` do app, sem `inkNotes` (vira anexo).
-- `owner_id` repete o dono do personagem para simplificar as permissões.
create table public.spell_sheet (
  id             uuid primary key,
  character_id   uuid not null references public.character,
  owner_id       uuid not null default auth.uid() references auth.users on delete cascade,
  session_id     uuid references public.session,
  ink_attachment uuid references public.attachment,
  data           jsonb not null,
  title text generated always as (data ->> 'title') stored,
  version        bigint      not null default 1,
  updated_at     timestamptz not null default now(),
  updated_by     uuid,
  change_seq     bigint      not null default nextval('public.sync_change_seq'),
  deleted_at     timestamptz,
  schema_version int         not null default 1,
  conflicted_at  timestamptz
);

-- Caderno individual: cada página é do autor (decisão Q3).
create table public.notebook_entry (
  id                 uuid primary key,
  campaign_id        uuid not null references public.campaign,
  author_id          uuid not null default auth.uid() references auth.users on delete cascade,
  date               timestamptz,
  title              text not null default '',
  text               text not null default '',
  kind               text,
  paper_style        text,
  drawing_attachment uuid references public.attachment,
  version        bigint      not null default 1,
  updated_at     timestamptz not null default now(),
  updated_by     uuid,
  change_seq     bigint      not null default nextval('public.sync_change_seq'),
  deleted_at     timestamptz,
  schema_version int         not null default 1,
  conflicted_at  timestamptz
);

-- Índices do pull ("tudo do usuário com change_seq > cursor") e das chaves.
create index campaign_owner_seq_idx       on public.campaign (owner_id, change_seq);
create index session_owner_seq_idx        on public.session (owner_id, change_seq);
create index session_campaign_idx         on public.session (campaign_id);
create index character_owner_seq_idx      on public.character (owner_id, change_seq);
create index character_campaign_idx       on public.character (campaign_id);
create index spell_sheet_owner_seq_idx    on public.spell_sheet (owner_id, change_seq);
create index spell_sheet_character_idx    on public.spell_sheet (character_id);
create index spell_sheet_session_idx      on public.spell_sheet (session_id);
create index notebook_entry_author_seq_idx on public.notebook_entry (author_id, change_seq);
create index notebook_entry_campaign_idx  on public.notebook_entry (campaign_id);
create index user_preferences_seq_idx     on public.user_preferences (change_seq);
create index character_portrait_idx       on public.character (portrait_attachment);
create index spell_sheet_ink_idx          on public.spell_sheet (ink_attachment);
create index notebook_entry_drawing_idx   on public.notebook_entry (drawing_attachment);

-- Trigger de sincronização em todas as tabelas sincronizáveis.
create trigger sync_before_write before insert or update on public.user_preferences
  for each row execute function public.sync_before_write();
create trigger sync_before_write before insert or update on public.campaign
  for each row execute function public.sync_before_write();
create trigger sync_before_write before insert or update on public.session
  for each row execute function public.sync_before_write();
create trigger sync_before_write before insert or update on public.character
  for each row execute function public.sync_before_write();
create trigger sync_before_write before insert or update on public.spell_sheet
  for each row execute function public.sync_before_write();
create trigger sync_before_write before insert or update on public.notebook_entry
  for each row execute function public.sync_before_write();

-- ---------------------------------------------------------------------------
-- Permissões (RLS). Fase 1: só o dono. Sem políticas de DELETE: exclusão é
-- sempre marcação em `deleted_at`.
-- ---------------------------------------------------------------------------

alter table public.user_preferences enable row level security;
alter table public.attachment       enable row level security;
alter table public.campaign         enable row level security;
alter table public.session          enable row level security;
alter table public.character        enable row level security;
alter table public.spell_sheet      enable row level security;
alter table public.notebook_entry   enable row level security;

create policy "dono lê" on public.user_preferences for select to authenticated
  using (user_id = (select auth.uid()));
create policy "dono cria" on public.user_preferences for insert to authenticated
  with check (user_id = (select auth.uid()));
create policy "dono edita" on public.user_preferences for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

create policy "dono lê" on public.attachment for select to authenticated
  using (owner_id = (select auth.uid()));
create policy "dono cria" on public.attachment for insert to authenticated
  with check (owner_id = (select auth.uid()));

create policy "dono lê" on public.campaign for select to authenticated
  using (owner_id = (select auth.uid()));
create policy "dono cria" on public.campaign for insert to authenticated
  with check (owner_id = (select auth.uid()));
create policy "dono edita" on public.campaign for update to authenticated
  using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()));

-- Sessão: do dono, e só dentro de campanha dele.
create policy "dono lê" on public.session for select to authenticated
  using (owner_id = (select auth.uid()));
create policy "dono cria" on public.session for insert to authenticated
  with check (owner_id = (select auth.uid()) and exists (
    select 1 from public.campaign c where c.id = campaign_id and c.owner_id = (select auth.uid())));
create policy "dono edita" on public.session for update to authenticated
  using (owner_id = (select auth.uid()))
  with check (owner_id = (select auth.uid()) and exists (
    select 1 from public.campaign c where c.id = campaign_id and c.owner_id = (select auth.uid())));

-- Personagem: do dono; se tiver campanha, a campanha também é dele.
create policy "dono lê" on public.character for select to authenticated
  using (owner_id = (select auth.uid()));
create policy "dono cria" on public.character for insert to authenticated
  with check (owner_id = (select auth.uid()) and (campaign_id is null or exists (
    select 1 from public.campaign c where c.id = campaign_id and c.owner_id = (select auth.uid()))));
create policy "dono edita" on public.character for update to authenticated
  using (owner_id = (select auth.uid()))
  with check (owner_id = (select auth.uid()) and (campaign_id is null or exists (
    select 1 from public.campaign c where c.id = campaign_id and c.owner_id = (select auth.uid()))));

-- Folha de magia: do dono, e o personagem também é dele.
create policy "dono lê" on public.spell_sheet for select to authenticated
  using (owner_id = (select auth.uid()));
create policy "dono cria" on public.spell_sheet for insert to authenticated
  with check (owner_id = (select auth.uid()) and exists (
    select 1 from public.character ch where ch.id = character_id and ch.owner_id = (select auth.uid())));
create policy "dono edita" on public.spell_sheet for update to authenticated
  using (owner_id = (select auth.uid()))
  with check (owner_id = (select auth.uid()) and exists (
    select 1 from public.character ch where ch.id = character_id and ch.owner_id = (select auth.uid())));

-- Caderno: só o autor (Q3); na Fase 1, dentro de campanha dele.
create policy "autor lê" on public.notebook_entry for select to authenticated
  using (author_id = (select auth.uid()));
create policy "autor cria" on public.notebook_entry for insert to authenticated
  with check (author_id = (select auth.uid()) and exists (
    select 1 from public.campaign c where c.id = campaign_id and c.owner_id = (select auth.uid())));
create policy "autor edita" on public.notebook_entry for update to authenticated
  using (author_id = (select auth.uid()))
  with check (author_id = (select auth.uid()) and exists (
    select 1 from public.campaign c where c.id = campaign_id and c.owner_id = (select auth.uid())));

-- ---------------------------------------------------------------------------
-- Arquivos (retrato, desenho do caderno, tinta da folha): bucket privado,
-- cada usuário só mexe na própria pasta <user_id>/.
-- ---------------------------------------------------------------------------

insert into storage.buckets (id, name, public)
values ('attachments', 'attachments', false)
on conflict (id) do nothing;

create policy "dono lê arquivos" on storage.objects for select to authenticated
  using (bucket_id = 'attachments' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "dono envia arquivos" on storage.objects for insert to authenticated
  with check (bucket_id = 'attachments' and (storage.foldername(name))[1] = (select auth.uid())::text);
