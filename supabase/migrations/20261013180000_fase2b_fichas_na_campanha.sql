-- Fase 2b: as fichas dos jogadores na campanha (2026-10-13;
-- docs/modelo-de-dados-e-sync.md §3, §4 e §8 Q1).
--
-- Decisões do usuário:
-- - o jogador põe a própria ficha numa campanha de que é membro (entrar na
--   campanha não leva fichas);
-- - o mestre lê e edita a ficha completa e as folhas de magia dos jogadores da
--   campanha dele, como se fosse o dono; gravações ao mesmo tempo seguem o
--   contrato de sempre (a última vence, `conflicted_at`, histórico);
-- - só o dono apaga a ficha (deleted_at) ou a tira da campanha; ninguém troca o
--   dono (`character_guard`). As funções da Fase 2a que devolvem fichas ao
--   Sandbox (sair, ser removido, campanha apagada) passam pela trava;
-- - os arquivos da ficha (retrato, tinta das folhas) seguem a ficha: quem lê a
--   ficha lê os arquivos, mesmo que outra conta os tenha enviado. O caderno
--   continua só do autor (Q3).

-- ---------------------------------------------------------------------------
-- Quem lê e edita uma ficha: o dono e o mestre da campanha dela.
-- ---------------------------------------------------------------------------

create function public.can_access_character(p_character uuid)
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

-- Um arquivo é legível por quem lê a ficha que o usa (retrato ou tinta de folha).
create function public.can_read_attachment(p_attachment uuid)
returns boolean
language sql stable
security definer
set search_path = ''
as $$
  select exists (
      select 1 from public.attachment a
      where a.id = p_attachment and a.owner_id = (select auth.uid()))
    or exists (
      select 1 from public.character c
      where c.portrait_attachment = p_attachment and public.can_access_character(c.id))
    or exists (
      select 1 from public.spell_sheet s
      where s.ink_attachment = p_attachment and public.can_access_character(s.character_id));
$$;

revoke execute on function public.can_access_character(uuid) from public, anon;
revoke execute on function public.can_read_attachment(uuid) from public, anon;
grant execute on function public.can_access_character(uuid) to authenticated;
grant execute on function public.can_read_attachment(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Trava da ficha: o dono não muda; só o dono apaga ou tira da campanha.
-- As funções do sistema (sair, remover, campanha apagada) ligam
-- `thac0berry.system` na transação para passar.
-- ---------------------------------------------------------------------------

create function public.character_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.owner_id is distinct from old.owner_id then
    raise exception 'owner_fixed' using errcode = '42501';
  end if;
  if coalesce(current_setting('thac0berry.system', true), '') <> 'on'
     and (select auth.uid()) is distinct from old.owner_id
     and (new.campaign_id is distinct from old.campaign_id or new.deleted_at is distinct from old.deleted_at) then
    raise exception 'owner_only' using errcode = '42501';
  end if;
  return new;
end;
$$;

create trigger character_guard before update on public.character
  for each row execute function public.character_guard();

-- Folha de magia: sempre no nome do dono da ficha (o mestre também cria).
create function public.spell_sheet_owner()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  select c.owner_id into new.owner_id from public.character c where c.id = new.character_id;
  return new;
end;
$$;

create trigger spell_sheet_owner before insert on public.spell_sheet
  for each row execute function public.spell_sheet_owner();

-- As funções da Fase 2a que devolvem fichas ao Sandbox passam pela trava.
create or replace function public.remove_campaign_member(p_campaign uuid, p_user uuid)
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
  perform set_config('thac0berry.system', 'on', true);
  update public.character set campaign_id = null where campaign_id = p_campaign and owner_id = p_user;
  perform set_config('thac0berry.system', '', true);
  delete from public.campaign_member where campaign_id = p_campaign and user_id = p_user;
end;
$$;

create or replace function public.campaign_after_delete_mark()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.deleted_at is not null and old.deleted_at is null then
    delete from public.campaign_invite where campaign_id = new.id;
    perform set_config('thac0berry.system', 'on', true);
    update public.character set campaign_id = null
      where campaign_id = new.id and owner_id <> new.owner_id;
    perform set_config('thac0berry.system', '', true);
    delete from public.campaign_member where campaign_id = new.id and role = 'player';
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Permissões
-- ---------------------------------------------------------------------------

-- Ficha: o dono, e o mestre da campanha dela; o dono põe em campanha de que é membro.
drop policy "dono lê" on public.character;
drop policy "dono cria" on public.character;
drop policy "dono edita" on public.character;
create policy "dono ou mestre lê" on public.character for select to authenticated
  using (owner_id = (select auth.uid()) or (campaign_id is not null and public.is_campaign_gm(campaign_id)));
create policy "dono cria" on public.character for insert to authenticated
  with check (owner_id = (select auth.uid()) and (campaign_id is null or public.is_campaign_member(campaign_id)));
create policy "dono ou mestre edita" on public.character for update to authenticated
  using (owner_id = (select auth.uid()) or (campaign_id is not null and public.is_campaign_gm(campaign_id)))
  with check (
    (owner_id = (select auth.uid()) and (campaign_id is null or public.is_campaign_member(campaign_id)))
    or (campaign_id is not null and public.is_campaign_gm(campaign_id)));

-- Folha de magia: igual à ficha.
drop policy "dono lê" on public.spell_sheet;
drop policy "dono cria" on public.spell_sheet;
drop policy "dono edita" on public.spell_sheet;
create policy "quem lê a ficha lê" on public.spell_sheet for select to authenticated
  using (public.can_access_character(character_id));
create policy "quem edita a ficha cria" on public.spell_sheet for insert to authenticated
  with check (public.can_access_character(character_id));
create policy "quem edita a ficha edita" on public.spell_sheet for update to authenticated
  using (public.can_access_character(character_id))
  with check (public.can_access_character(character_id));

-- Arquivos: o registro e o objeto, para quem lê a ficha que os usa.
drop policy "dono lê" on public.attachment;
create policy "dono ou quem lê a ficha lê" on public.attachment for select to authenticated
  using (owner_id = (select auth.uid()) or public.can_read_attachment(id));

create policy "quem lê a ficha lê arquivos" on storage.objects for select to authenticated
  using (bucket_id = 'attachments' and exists (
    select 1 from public.attachment a where a.storage_path = name and public.can_read_attachment(a.id)));
