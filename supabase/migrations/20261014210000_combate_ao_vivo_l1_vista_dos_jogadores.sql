-- Combat Tracker ao vivo, L1 (2026-10-14; web docs/controle-de-combate.md):
-- a "vista dos jogadores" de um encontro.
--
-- O encontro (`encounter`) é só do mestre: o JSON tem PV, CA, moral, XP e notas
-- dos inimigos, e a RLS não filtra campos dentro do JSON. Por isso o app do
-- mestre monta uma versão FILTRADA (o que os jogadores podem ver) e a publica
-- aqui; os membros da campanha a leem ao vivo (Realtime). Os segredos nunca
-- saem do aparelho do mestre.
--
-- Decisões do usuário: o mestre liga "Show to players" por encontro (só em
-- encontro de campanha); estado dos inimigos em palavras, sem PV; a reação
-- (Tabela 59) não vai; os jogadores só veem (interagir fica para depois).
--
-- É uma projeção, substituída inteira a cada mudança: não segue o contrato de
-- versão das tabelas sincronizadas. Só se escreve pelas funções abaixo
-- (security definer, que conferem o mestre); sem GRANT de escrita direta.

create table public.encounter_view (
  encounter_id uuid primary key references public.encounter on delete cascade,
  campaign_id  uuid not null references public.campaign on delete cascade,
  owner_id     uuid not null references auth.users on delete cascade,
  data         jsonb not null,
  updated_at   timestamptz not null default now()
);

create index encounter_view_campaign_idx on public.encounter_view (campaign_id);

alter table public.encounter_view enable row level security;

-- Lê quem é da campanha (o mestre e os jogadores).
create policy "membro lê" on public.encounter_view for select to authenticated
  using ((select public.is_campaign_member(campaign_id)));

grant select on public.encounter_view to authenticated;

alter publication supabase_realtime add table public.encounter_view;

-- ---------------------------------------------------------------------------
-- Publicar: só o dono do encontro, se o encontro for de uma campanha dele.
-- ---------------------------------------------------------------------------

create function public.publish_encounter_view(p_encounter uuid, p_data jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_campaign uuid;
begin
  select e.campaign_id into v_campaign
  from public.encounter e
  where e.id = p_encounter and e.owner_id = (select auth.uid()) and e.deleted_at is null;
  if not found then
    raise exception 'encounter not found' using errcode = '42501';
  end if;
  if v_campaign is null then
    raise exception 'only campaign encounters can be shown to players' using errcode = '22023';
  end if;
  if not public.is_campaign_gm(v_campaign) then
    raise exception 'not the dungeon master of this campaign' using errcode = '42501';
  end if;
  if jsonb_typeof(p_data) <> 'object' or pg_column_size(p_data) > 262144 then
    raise exception 'invalid view' using errcode = '22023';
  end if;
  insert into public.encounter_view (encounter_id, campaign_id, owner_id, data, updated_at)
  values (p_encounter, v_campaign, (select auth.uid()), p_data, now())
  on conflict (encounter_id) do update
    set campaign_id = excluded.campaign_id, data = excluded.data, updated_at = now();
end;
$$;

-- Tirar dos jogadores (desligar, encerrar ou apagar o encontro).
create function public.unpublish_encounter_view(p_encounter uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  delete from public.encounter_view v
  where v.encounter_id = p_encounter and v.owner_id = (select auth.uid());
$$;

revoke execute on function public.publish_encounter_view(uuid, jsonb) from public, anon;
revoke execute on function public.unpublish_encounter_view(uuid) from public, anon;
grant execute on function public.publish_encounter_view(uuid, jsonb) to authenticated;
grant execute on function public.unpublish_encounter_view(uuid) to authenticated;
