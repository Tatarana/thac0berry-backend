-- Fase 2c: resumo do grupo e acesso temporário (2026-10-13;
-- docs/modelo-de-dados-e-sync.md §3, §4 e §8 Q1/Q2).
--
-- Decisões do usuário:
-- - os membros da campanha veem o resumo das fichas dos outros (nome, classe,
--   nível e PV); a ficha completa continua só do dono, do mestre e de quem tem
--   acesso temporário (Q2);
-- - o mestre dá a um jogador acesso de edição à ficha de outro (quem faltou à
--   sessão) por 24 h, ou até revogar (Q1). Quem recebeu também pode devolver.
--   O acesso deixa de valer sozinho se expirar, for revogado ou o jogador sair da
--   campanha (ou a ficha sair dela). Com ele, o jogador lê e edita a ficha e as
--   folhas, mas não apaga a ficha nem a tira da campanha (`character_grant` não
--   passa pela trava `character_guard`, que é só do dono).

create table public.character_grant (
  id           uuid primary key default gen_random_uuid(),
  character_id uuid not null references public.character on delete cascade,
  grantee_id   uuid not null references auth.users on delete cascade,
  granted_by   uuid not null references auth.users on delete cascade,
  created_at   timestamptz not null default now(),
  expires_at   timestamptz not null,
  revoked_at   timestamptz
);

create index character_grant_grantee_idx on public.character_grant (grantee_id);
create index character_grant_character_idx on public.character_grant (character_id);

-- ---------------------------------------------------------------------------
-- Acesso válido: não revogado, não expirado, a ficha numa campanha de que quem
-- recebeu ainda é membro.
-- ---------------------------------------------------------------------------

create function public.has_character_grant(p_character uuid)
returns boolean
language sql stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.character_grant g
    join public.character c on c.id = g.character_id
    join public.campaign_member m on m.campaign_id = c.campaign_id and m.user_id = g.grantee_id
    where g.character_id = p_character
      and g.grantee_id = (select auth.uid())
      and g.revoked_at is null
      and g.expires_at > now()
      and c.deleted_at is null);
$$;

-- Quem lê e edita a ficha: o dono, o mestre da campanha e quem tem acesso válido.
create or replace function public.can_access_character(p_character uuid)
returns boolean
language sql stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.character c
    where c.id = p_character
      and (c.owner_id = (select auth.uid())
           or (c.campaign_id is not null and public.is_campaign_gm(c.campaign_id))))
    or public.has_character_grant(p_character);
$$;

-- O dono da ficha ou o mestre da campanha dela (quem vê os acessos dados).
create function public.can_manage_grants(p_character uuid)
returns boolean
language sql stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.character c
    where c.id = p_character
      and (c.owner_id = (select auth.uid())
           or (c.campaign_id is not null and public.is_campaign_gm(c.campaign_id))));
$$;

-- ---------------------------------------------------------------------------
-- Funções (RPC). Erros: 'not_gm', 'not_member', 'invalid_grantee', 'invalid_hours',
-- 'not_found'.
-- ---------------------------------------------------------------------------

create function public.grant_character_access(p_character uuid, p_grantee uuid, p_hours int default 24)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_campaign uuid;
  v_owner uuid;
  v_id uuid;
begin
  select c.campaign_id, c.owner_id into v_campaign, v_owner
    from public.character c where c.id = p_character and c.deleted_at is null;
  if v_campaign is null or not public.is_campaign_gm(v_campaign) then
    raise exception 'not_gm' using errcode = '42501';
  end if;
  if p_grantee = v_owner or not exists (
    select 1 from public.campaign_member m
    where m.campaign_id = v_campaign and m.user_id = p_grantee and m.role = 'player') then
    raise exception 'invalid_grantee' using errcode = '22023';
  end if;
  if p_hours is null or p_hours < 1 or p_hours > 168 then
    raise exception 'invalid_hours' using errcode = '22023';
  end if;
  -- Um acesso ativo por pessoa e ficha: o novo substitui o anterior.
  update public.character_grant set revoked_at = now()
    where character_id = p_character and grantee_id = p_grantee and revoked_at is null;
  insert into public.character_grant (character_id, grantee_id, granted_by, expires_at)
  values (p_character, p_grantee, (select auth.uid()), now() + make_interval(hours => p_hours))
  returning id into v_id;
  return v_id;
end;
$$;

-- O mestre revoga; quem recebeu também pode devolver.
create function public.revoke_character_access(p_grant uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_grant public.character_grant;
begin
  select * into v_grant from public.character_grant where id = p_grant;
  if v_grant.id is null then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if not (v_grant.grantee_id = (select auth.uid()) or exists (
    select 1 from public.character c
    where c.id = v_grant.character_id and c.campaign_id is not null and public.is_campaign_gm(c.campaign_id))) then
    raise exception 'not_gm' using errcode = '42501';
  end if;
  update public.character_grant set revoked_at = now() where id = p_grant and revoked_at is null;
end;
$$;

-- Resumo do grupo: as fichas da campanha (de todos os membros), com o nome de
-- quem joga, classe, nível, estado e PV, e se a conta pode abrir a ficha completa.
create function public.campaign_party(p_campaign uuid)
returns table (
  id uuid,
  owner_id uuid,
  player_name text,
  name text,
  character_class text,
  level int,
  status text,
  hit_points_current int,
  hit_points_max int,
  can_edit boolean
)
language plpgsql stable
security definer
set search_path = ''
as $$
begin
  if not public.is_campaign_member(p_campaign) then
    raise exception 'not_member' using errcode = '42501';
  end if;
  return query
    select c.id, c.owner_id, coalesce(m.display_name, ''), c.name, c.character_class, c.level, c.status,
           case when c.data ->> 'hitPointsCurrent' ~ '^-?\d+$' then (c.data ->> 'hitPointsCurrent')::int end,
           case when c.data ->> 'hitPointsMax' ~ '^-?\d+$' then (c.data ->> 'hitPointsMax')::int end,
           public.can_access_character(c.id)
    from public.character c
    left join public.campaign_member m on m.campaign_id = c.campaign_id and m.user_id = c.owner_id
    where c.campaign_id = p_campaign and c.deleted_at is null
    order by c.name;
end;
$$;

revoke execute on function public.has_character_grant(uuid) from public, anon;
revoke execute on function public.can_manage_grants(uuid) from public, anon;
revoke execute on function public.grant_character_access(uuid, uuid, int) from public, anon;
revoke execute on function public.revoke_character_access(uuid) from public, anon;
revoke execute on function public.campaign_party(uuid) from public, anon;
grant execute on function public.has_character_grant(uuid) to authenticated;
grant execute on function public.can_manage_grants(uuid) to authenticated;
grant execute on function public.grant_character_access(uuid, uuid, int) to authenticated;
grant execute on function public.revoke_character_access(uuid) to authenticated;
grant execute on function public.campaign_party(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Permissões
-- ---------------------------------------------------------------------------

alter table public.character_grant enable row level security;
-- Vê os acessos: quem recebeu, o dono da ficha e o mestre. Gravar só pelas funções.
create policy "envolvidos leem" on public.character_grant for select to authenticated
  using (grantee_id = (select auth.uid()) or public.can_manage_grants(character_id));
grant select on public.character_grant to authenticated;

-- Ficha: também quem tem acesso válido (lê e edita; apagar e tirar da campanha
-- continuam só do dono, pela trava).
drop policy "dono ou mestre lê" on public.character;
drop policy "dono ou mestre edita" on public.character;
create policy "dono, mestre ou acesso lê" on public.character for select to authenticated
  using (owner_id = (select auth.uid())
         or (campaign_id is not null and public.is_campaign_gm(campaign_id))
         or public.has_character_grant(id));
create policy "dono, mestre ou acesso edita" on public.character for update to authenticated
  using (owner_id = (select auth.uid())
         or (campaign_id is not null and public.is_campaign_gm(campaign_id))
         or public.has_character_grant(id))
  with check (
    (owner_id = (select auth.uid()) and (campaign_id is null or public.is_campaign_member(campaign_id)))
    or (campaign_id is not null and public.is_campaign_gm(campaign_id))
    or (campaign_id is not null and public.has_character_grant(id)));
