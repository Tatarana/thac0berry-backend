-- Fase 2a: campanha compartilhada, entrar por convite (2026-10-13;
-- docs/modelo-de-dados-e-sync.md §3, §4, §8 Q4 e §9).
--
-- Decisões do usuário:
-- - convite por código: um código ativo por campanha, sem prazo, válido até o
--   mestre revogar ou trocar, usável por vários jogadores; o mestre gera um
--   aleatório (6 caracteres fáceis de ditar) ou escolhe o dele (uma "senha"
--   comum do grupo). O código é único entre os ativos de todas as campanhas e
--   não diferencia maiúsculas;
-- - jogador que sai ou é removido: as fichas dele continuam dele e voltam ao
--   Sandbox (sem campanha); o mestre apagar a campanha faz o mesmo;
-- - o mestre é quem criou a campanha (`campaign.owner_id`), com uma linha
--   `gm` em `campaign_member`; os jogadores entram como `player`.
--
-- Membros e convites só mudam pelas funções abaixo (security definer): o
-- cliente lê as tabelas, mas não grava nelas. As fichas dos jogadores na
-- campanha (o mestre lendo e editando) são a Fase 2b.

-- ---------------------------------------------------------------------------
-- Tabelas
-- ---------------------------------------------------------------------------

create table public.campaign_member (
  campaign_id  uuid not null references public.campaign on delete cascade,
  user_id      uuid not null references auth.users on delete cascade,
  role         text not null check (role in ('gm', 'player')),
  -- Nome que o mestre e o grupo veem (o "nome padrão do jogador" de quem entrou,
  -- ou o que ele digitou); auth.users não é visível para os outros.
  display_name text not null default '',
  joined_at    timestamptz not null default now(),
  primary key (campaign_id, user_id)
);

create index campaign_member_user_idx on public.campaign_member (user_id);

create table public.campaign_invite (
  campaign_id uuid primary key references public.campaign on delete cascade,
  code        text not null,
  created_by  uuid not null references auth.users on delete cascade,
  created_at  timestamptz not null default now()
);

-- Único sem diferenciar maiúsculas (a função já grava em maiúsculas).
create unique index campaign_invite_code_idx on public.campaign_invite (upper(code));

-- ---------------------------------------------------------------------------
-- Quem é quem (para as políticas; security definer evita recursão no RLS)
-- ---------------------------------------------------------------------------

create function public.is_campaign_gm(p_campaign uuid)
returns boolean
language sql stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.campaign c
    where c.id = p_campaign and c.owner_id = (select auth.uid()) and c.deleted_at is null);
$$;

create function public.is_campaign_member(p_campaign uuid)
returns boolean
language sql stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.campaign c
    where c.id = p_campaign and c.deleted_at is null
      and (c.owner_id = (select auth.uid()) or exists (
        select 1 from public.campaign_member m
        where m.campaign_id = c.id and m.user_id = (select auth.uid()))));
$$;

-- ---------------------------------------------------------------------------
-- O mestre é membro `gm` (campanhas novas pelo trigger; as que já existem aqui)
-- ---------------------------------------------------------------------------

create function public.campaign_add_gm()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.campaign_member (campaign_id, user_id, role)
  values (new.id, new.owner_id, 'gm')
  on conflict (campaign_id, user_id) do nothing;
  return new;
end;
$$;

create trigger campaign_add_gm after insert on public.campaign
  for each row execute function public.campaign_add_gm();

insert into public.campaign_member (campaign_id, user_id, role)
select id, owner_id, 'gm' from public.campaign
on conflict (campaign_id, user_id) do nothing;

-- ---------------------------------------------------------------------------
-- Campanha apagada (marcada em deleted_at): convite e jogadores saem, e as
-- fichas dos jogadores voltam ao Sandbox.
-- ---------------------------------------------------------------------------

create function public.campaign_after_delete_mark()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.deleted_at is not null and old.deleted_at is null then
    delete from public.campaign_invite where campaign_id = new.id;
    update public.character set campaign_id = null
      where campaign_id = new.id and owner_id <> new.owner_id;
    delete from public.campaign_member where campaign_id = new.id and role = 'player';
  end if;
  return new;
end;
$$;

create trigger campaign_after_delete_mark after update of deleted_at on public.campaign
  for each row execute function public.campaign_after_delete_mark();

-- ---------------------------------------------------------------------------
-- Funções do convite e dos membros (o cliente chama por RPC)
-- Erros: 'not_gm', 'invalid_code', 'code_in_use', 'invalid_invite',
-- 'not_member' (mensagem da exceção; a web traduz).
-- ---------------------------------------------------------------------------

-- Gera (p_code nulo ou vazio) ou define o código do convite; troca o anterior.
create function public.set_campaign_invite(p_campaign uuid, p_code text default null)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';  -- sem 0/O, 1/I
  v_code text;
  i int;
begin
  if not public.is_campaign_gm(p_campaign) then
    raise exception 'not_gm' using errcode = '42501';
  end if;
  if nullif(trim(coalesce(p_code, '')), '') is null then
    loop
      v_code := '';
      for i in 1..6 loop
        v_code := v_code || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1);
      end loop;
      exit when not exists (
        select 1 from public.campaign_invite where upper(code) = v_code and campaign_id <> p_campaign);
    end loop;
  else
    v_code := upper(trim(p_code));
    -- Letras sem acento, algarismos e hífen; de 4 a 24 caracteres.
    if v_code !~ '^[A-Z0-9-]{4,24}$' then
      raise exception 'invalid_code' using errcode = '22023';
    end if;
    if exists (select 1 from public.campaign_invite where upper(code) = v_code and campaign_id <> p_campaign) then
      raise exception 'code_in_use' using errcode = '23505';
    end if;
  end if;
  insert into public.campaign_invite (campaign_id, code, created_by)
  values (p_campaign, v_code, (select auth.uid()))
  on conflict (campaign_id) do update set code = excluded.code, created_by = excluded.created_by, created_at = now();
  return v_code;
end;
$$;

create function public.revoke_campaign_invite(p_campaign uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_campaign_gm(p_campaign) then
    raise exception 'not_gm' using errcode = '42501';
  end if;
  delete from public.campaign_invite where campaign_id = p_campaign;
end;
$$;

-- Entra na campanha do código como jogador (ou só atualiza o nome, se já for
-- membro); devolve o id da campanha.
create function public.join_campaign(p_code text, p_display_name text default '')
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_campaign uuid;
  v_owner uuid;
begin
  if (select auth.uid()) is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select i.campaign_id, c.owner_id into v_campaign, v_owner
    from public.campaign_invite i join public.campaign c on c.id = i.campaign_id
    where upper(i.code) = upper(trim(coalesce(p_code, ''))) and c.deleted_at is null;
  if v_campaign is null then
    raise exception 'invalid_invite' using errcode = 'P0002';
  end if;
  if v_owner = (select auth.uid()) then
    return v_campaign;
  end if;
  insert into public.campaign_member (campaign_id, user_id, role, display_name)
  values (v_campaign, (select auth.uid()), 'player', left(trim(coalesce(p_display_name, '')), 80))
  on conflict (campaign_id, user_id) do update
    set display_name = case when excluded.display_name = '' then public.campaign_member.display_name else excluded.display_name end;
  return v_campaign;
end;
$$;

-- Tira um jogador (o mestre tira qualquer um; o jogador, a si mesmo). As fichas
-- dele naquela campanha voltam ao Sandbox.
create function public.remove_campaign_member(p_campaign uuid, p_user uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not (public.is_campaign_gm(p_campaign) or p_user = (select auth.uid())) then
    raise exception 'not_gm' using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.campaign_member where campaign_id = p_campaign and user_id = p_user and role = 'player') then
    raise exception 'not_member' using errcode = 'P0002';
  end if;
  update public.character set campaign_id = null where campaign_id = p_campaign and owner_id = p_user;
  delete from public.campaign_member where campaign_id = p_campaign and user_id = p_user;
end;
$$;

revoke execute on function public.set_campaign_invite(uuid, text) from public, anon;
revoke execute on function public.revoke_campaign_invite(uuid) from public, anon;
revoke execute on function public.join_campaign(text, text) from public, anon;
revoke execute on function public.remove_campaign_member(uuid, uuid) from public, anon;
revoke execute on function public.is_campaign_gm(uuid) from public, anon;
revoke execute on function public.is_campaign_member(uuid) from public, anon;
grant execute on function public.set_campaign_invite(uuid, text) to authenticated;
grant execute on function public.revoke_campaign_invite(uuid) to authenticated;
grant execute on function public.join_campaign(text, text) to authenticated;
grant execute on function public.remove_campaign_member(uuid, uuid) to authenticated;
grant execute on function public.is_campaign_gm(uuid) to authenticated;
grant execute on function public.is_campaign_member(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Permissões
-- ---------------------------------------------------------------------------

alter table public.campaign_member enable row level security;
alter table public.campaign_invite enable row level security;

-- Membros: quem é da campanha vê todos os membros dela.
create policy "membro lê" on public.campaign_member for select to authenticated
  using (public.is_campaign_member(campaign_id));
-- Convite: só o mestre vê o código.
create policy "mestre lê" on public.campaign_invite for select to authenticated
  using (public.is_campaign_gm(campaign_id));

grant select on public.campaign_member to authenticated;
grant select on public.campaign_invite to authenticated;

-- Campanha: membros também leem (editar continua só o mestre).
drop policy "dono lê" on public.campaign;
create policy "membro lê" on public.campaign for select to authenticated
  using (owner_id = (select auth.uid()) or public.is_campaign_member(id));

-- Sessão: membros leem, criam e editam (mestre e jogadores, §4).
drop policy "dono lê" on public.session;
drop policy "dono cria" on public.session;
drop policy "dono edita" on public.session;
create policy "membro lê" on public.session for select to authenticated
  using (owner_id = (select auth.uid()) or public.is_campaign_member(campaign_id));
create policy "membro cria" on public.session for insert to authenticated
  with check (owner_id = (select auth.uid()) and public.is_campaign_member(campaign_id));
create policy "membro edita" on public.session for update to authenticated
  using (public.is_campaign_member(campaign_id))
  with check (public.is_campaign_member(campaign_id));
