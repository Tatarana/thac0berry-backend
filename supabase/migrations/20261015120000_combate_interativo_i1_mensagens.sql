-- Combat Tracker interativo, I1 (2026-10-15; web docs/controle-de-combate.md):
-- mensagens entre o mestre e os jogadores durante um encontro compartilhado.
--
-- Decisão do usuário: nos dois sentidos, quem recebe ACEITA antes de valer:
-- - jogador → mestre (ex.: o d10 da iniciativa, o d20 de um salvamento): o
--   mestre aceita para o número entrar no Combat Tracker;
-- - mestre → jogador (ex.: dano ou cura no PC): o jogador aceita para a ficha
--   mudar (é o app do jogador que grava a própria ficha).
--
-- A tabela é genérica (`kind` + `payload`): o que cada tipo significa fica na
-- web. Só se escreve pelas funções abaixo (security definer), que conferem
-- quem pode mandar e quem pode responder; sem GRANT de escrita direta.
-- Quem fala pelo personagem: o dono ou quem tem o acesso temporário (Fase 2c).

create table public.combat_message (
  id           uuid primary key default gen_random_uuid(),
  campaign_id  uuid not null references public.campaign on delete cascade,
  encounter_id uuid not null references public.encounter on delete cascade,
  character_id uuid not null references public.character on delete cascade,
  direction    text not null check (direction in ('to_dm', 'to_player')),
  kind         text not null check (kind ~ '^[a-z_]{1,32}$'),
  payload      jsonb not null check (jsonb_typeof(payload) = 'object' and pg_column_size(payload) <= 8192),
  status       text not null default 'pending' check (status in ('pending', 'accepted', 'declined', 'withdrawn')),
  created_by   uuid not null default auth.uid() references auth.users on delete cascade,
  created_at   timestamptz not null default now(),
  resolved_by  uuid references auth.users on delete set null,
  resolved_at  timestamptz
);

create index combat_message_encounter_idx on public.combat_message (encounter_id, created_at);
create index combat_message_character_idx on public.combat_message (character_id, status);
create index combat_message_campaign_idx  on public.combat_message (campaign_id);

-- Fala pelo personagem: o dono, ou quem tem o acesso temporário dele.
create function public.speaks_for_character(p_character uuid)
returns boolean
language sql stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.character c where c.id = p_character and c.owner_id = (select auth.uid()))
      or public.has_character_grant(p_character);
$$;

alter table public.combat_message enable row level security;

-- Lê o mestre da campanha e quem fala pelo personagem.
create policy "mestre ou jogador do personagem lê" on public.combat_message for select to authenticated
  using ((select public.is_campaign_gm(campaign_id)) or (select public.speaks_for_character(character_id)));

grant select on public.combat_message to authenticated;

alter publication supabase_realtime add table public.combat_message;

-- ---------------------------------------------------------------------------
-- Mandar
-- ---------------------------------------------------------------------------

-- O encontro, a campanha dele e o personagem nela; erro se não batem.
create function public.combat_message_target(p_encounter uuid, p_character uuid)
returns uuid
language plpgsql stable
security definer
set search_path = ''
as $$
declare
  v_campaign uuid;
begin
  select e.campaign_id into v_campaign from public.encounter e where e.id = p_encounter and e.deleted_at is null;
  if v_campaign is null then
    raise exception 'encounter not found' using errcode = '42501';
  end if;
  if not exists (select 1 from public.character c where c.id = p_character and c.campaign_id = v_campaign and c.deleted_at is null) then
    raise exception 'character not in this campaign' using errcode = '42501';
  end if;
  return v_campaign;
end;
$$;

-- Jogador → mestre: só pelo próprio personagem, e só num encontro que o mestre
-- está mostrando aos jogadores (tem vista publicada).
create function public.send_to_dm(p_encounter uuid, p_character uuid, p_kind text, p_payload jsonb)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_campaign uuid := public.combat_message_target(p_encounter, p_character);
  v_id uuid;
begin
  if not public.speaks_for_character(p_character) then
    raise exception 'not your character' using errcode = '42501';
  end if;
  if not exists (select 1 from public.encounter_view v where v.encounter_id = p_encounter) then
    raise exception 'this encounter is not shown to the players' using errcode = '42501';
  end if;
  if (select count(*) from public.combat_message m where m.character_id = p_character and m.status = 'pending') >= 20 then
    raise exception 'too many pending messages' using errcode = '22023';
  end if;
  insert into public.combat_message (campaign_id, encounter_id, character_id, direction, kind, payload)
  values (v_campaign, p_encounter, p_character, 'to_dm', p_kind, p_payload)
  returning id into v_id;
  return v_id;
end;
$$;

-- Mestre → jogador: o dono do encontro, mestre da campanha.
create function public.send_to_player(p_encounter uuid, p_character uuid, p_kind text, p_payload jsonb)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_campaign uuid := public.combat_message_target(p_encounter, p_character);
  v_id uuid;
begin
  if not exists (select 1 from public.encounter e where e.id = p_encounter and e.owner_id = (select auth.uid()))
     or not public.is_campaign_gm(v_campaign) then
    raise exception 'not the dungeon master of this encounter' using errcode = '42501';
  end if;
  if (select count(*) from public.combat_message m where m.character_id = p_character and m.status = 'pending') >= 20 then
    raise exception 'too many pending messages' using errcode = '22023';
  end if;
  insert into public.combat_message (campaign_id, encounter_id, character_id, direction, kind, payload)
  values (v_campaign, p_encounter, p_character, 'to_player', p_kind, p_payload)
  returning id into v_id;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Responder (quem recebe) e retirar (quem mandou), só enquanto pendente.
-- ---------------------------------------------------------------------------

create function public.resolve_combat_message(p_message uuid, p_accept boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  m public.combat_message;
begin
  select * into m from public.combat_message where id = p_message for update;
  if not found or m.status <> 'pending' then
    raise exception 'message not pending' using errcode = '22023';
  end if;
  if (m.direction = 'to_dm' and not public.is_campaign_gm(m.campaign_id))
     or (m.direction = 'to_player' and not public.speaks_for_character(m.character_id)) then
    raise exception 'not the recipient' using errcode = '42501';
  end if;
  update public.combat_message
  set status = case when p_accept then 'accepted' else 'declined' end, resolved_by = (select auth.uid()), resolved_at = now()
  where id = p_message;
end;
$$;

create function public.withdraw_combat_message(p_message uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.combat_message
  set status = 'withdrawn', resolved_by = (select auth.uid()), resolved_at = now()
  where id = p_message and status = 'pending' and created_by = (select auth.uid());
  if not found then
    raise exception 'message not pending or not yours' using errcode = '22023';
  end if;
end;
$$;

revoke execute on function public.speaks_for_character(uuid) from public, anon;
revoke execute on function public.combat_message_target(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.send_to_dm(uuid, uuid, text, jsonb) from public, anon;
revoke execute on function public.send_to_player(uuid, uuid, text, jsonb) from public, anon;
revoke execute on function public.resolve_combat_message(uuid, boolean) from public, anon;
revoke execute on function public.withdraw_combat_message(uuid) from public, anon;
grant execute on function public.speaks_for_character(uuid) to authenticated;
grant execute on function public.send_to_dm(uuid, uuid, text, jsonb) to authenticated;
grant execute on function public.send_to_player(uuid, uuid, text, jsonb) to authenticated;
grant execute on function public.resolve_combat_message(uuid, boolean) to authenticated;
grant execute on function public.withdraw_combat_message(uuid) to authenticated;
