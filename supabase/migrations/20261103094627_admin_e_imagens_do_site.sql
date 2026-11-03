-- Perfil Admin e imagens do site versionadas (2026-11-03; proposta aprovada na
-- conversa, decisões do usuário):
-- - Admin é uma lista de e-mails (`app_admin`), começando por
--   fernando.hreis@gmail.com. Vale para a conta com esse e-mail confirmado (o
--   login do Google confirma).
-- - As imagens trocáveis navegando pelo app (personagens do The Forge; depois
--   o Grimório, principalmente o Monstrous Manual) ficam no bucket público
--   `site-images`: qualquer um lê, inclusive sem login; só o admin envia.
-- - Cada envio é uma versão nova de um "slot" (ex.: `forge/race-dwarf-male`,
--   `monster/<id>`), numerada 1, 2, 3…; uma delas é a atual. Nenhuma versão é
--   apagada, nunca (nem o arquivo, nem a linha).
-- - As imagens que já estão no repo da web entram como versão 1 (script da
--   web, com a chave service_role na máquina do usuário; nunca no repo).
-- - A web converte para WebP e ajusta o tamanho antes de enviar.

-- ---------------------------------------------------------------------------
-- Admin
-- ---------------------------------------------------------------------------

create table public.app_admin (
  email    text primary key check (email = lower(email)),
  added_at timestamptz not null default now()
);
-- Sem GRANT: ninguém lê nem grava pela API; só is_admin() consulta (security
-- definer). Incluir outro admin é uma migração.
alter table public.app_admin enable row level security;

insert into public.app_admin (email) values ('fernando.hreis@gmail.com');

-- O usuário logado é admin? Pelo e-mail da conta (auth.users), e só com o
-- e-mail confirmado: um cadastro por senha com o mesmo e-mail, ainda não
-- confirmado, não vira admin.
create function public.is_admin()
returns boolean
language sql stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from auth.users u
    join public.app_admin a on a.email = lower(u.email)
    where u.id = (select auth.uid()) and u.email_confirmed_at is not null);
$$;
grant execute on function public.is_admin() to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Arquivos: bucket público, só WebP, até 5 MB. O caminho é
-- `<slot>/<uuid>.webp`; não há política de UPDATE nem de DELETE.
-- ---------------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('site-images', 'site-images', true, 5242880, array['image/webp'])
on conflict (id) do nothing;

create policy "todos leem imagens do site" on storage.objects for select to anon, authenticated
  using (bucket_id = 'site-images');
create policy "admin envia imagens do site" on storage.objects for insert to authenticated
  with check (bucket_id = 'site-images' and (select public.is_admin()));

-- ---------------------------------------------------------------------------
-- Versões
-- ---------------------------------------------------------------------------

create table public.site_image_version (
  id           uuid primary key default gen_random_uuid(),
  -- `area/nome`, minúsculas: forge/race-dwarf-male, monster/beholder…
  slot         text not null check (slot ~ '^[a-z0-9-]+(/[a-z0-9._-]+)+$'),
  version      int  not null check (version > 0),
  -- Caminho no bucket site-images.
  storage_path text not null unique,
  width        int  check (width > 0),
  height       int  check (height > 0),
  uploaded_by  uuid references auth.users on delete set null,
  uploaded_at  timestamptz not null default now(),
  is_current   boolean not null default false,
  unique (slot, version)
);
-- Uma atual por slot.
create unique index site_image_version_current_idx on public.site_image_version (slot) where is_current;
alter table public.site_image_version enable row level security;

-- Todos leem (a web carrega as atuais uma vez por sessão). Gravar, só pelas
-- funções abaixo.
create policy "todos leem as versões" on public.site_image_version for select to anon, authenticated
  using (true);
grant select on public.site_image_version to anon, authenticated;

-- Quem pode gravar: o admin logado ou a chave service_role (o script da
-- versão 1).
create function public.can_manage_site_images()
returns boolean
language sql stable
security definer
set search_path = ''
as $$
  select (select auth.role()) = 'service_role' or public.is_admin();
$$;

-- Registra o arquivo já enviado ao bucket como a versão seguinte do slot e a
-- torna a atual. Devolve o número da versão.
create function public.add_site_image_version(p_slot text, p_storage_path text, p_width int default null, p_height int default null)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v int;
begin
  if not public.can_manage_site_images() then
    raise exception 'só o admin troca imagens do site' using errcode = '42501';
  end if;
  if not exists (select 1 from storage.objects o where o.bucket_id = 'site-images' and o.name = p_storage_path) then
    raise exception 'arquivo % não está no bucket site-images', p_storage_path using errcode = 'P0002';
  end if;
  if left(p_storage_path, length(p_slot) + 1) <> p_slot || '/' then
    raise exception 'o arquivo tem de estar na pasta do slot (%/…)', p_slot using errcode = '22023';
  end if;
  -- Dois envios ao mesmo tempo no mesmo slot: um espera o outro.
  perform pg_advisory_xact_lock(hashtext('site_image:' || p_slot));
  select coalesce(max(s.version), 0) + 1 into v from public.site_image_version s where s.slot = p_slot;
  update public.site_image_version set is_current = false where slot = p_slot and is_current;
  insert into public.site_image_version (slot, version, storage_path, width, height, uploaded_by, is_current)
  values (p_slot, v, p_storage_path, p_width, p_height, (select auth.uid()), true);
  return v;
end;
$$;

-- Volta (ou avança) o slot para uma versão que já existe.
create function public.set_current_site_image(p_slot text, p_version int)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.can_manage_site_images() then
    raise exception 'só o admin troca imagens do site' using errcode = '42501';
  end if;
  if not exists (select 1 from public.site_image_version s where s.slot = p_slot and s.version = p_version) then
    raise exception 'o slot % não tem a versão %', p_slot, p_version using errcode = 'P0002';
  end if;
  perform pg_advisory_xact_lock(hashtext('site_image:' || p_slot));
  update public.site_image_version set is_current = false where slot = p_slot and is_current;
  update public.site_image_version set is_current = true where slot = p_slot and version = p_version;
end;
$$;

revoke all on function public.can_manage_site_images() from public, anon;
revoke all on function public.add_site_image_version(text, text, int, int) from public, anon;
revoke all on function public.set_current_site_image(text, int) from public, anon;
grant execute on function public.add_site_image_version(text, text, int, int) to authenticated, service_role;
grant execute on function public.set_current_site_image(text, int) to authenticated, service_role;
