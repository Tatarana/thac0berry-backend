-- Imagens do site fora do Supabase Storage (2026-11-04; desenho em
-- docs/imagens-fora-do-supabase.md). Os arquivos passam a viver num bucket S3
-- atrás do CloudFront; no Supabase ficam o login, o perfil Admin e a tabela
-- site_image_version.
--
-- O que muda: `add_site_image_version` deixa de conferir `storage.objects`
-- (o arquivo já não está lá). Quem confere que o arquivo chegou ao S3 é a Edge
-- Function `site-image-upload` (ação `finalize`), antes de chamar esta função
-- com o login do admin. Continuam valendo a checagem de permissão, a da pasta
-- do slot e o lock que serializa envios ao mesmo slot.
--
-- Não muda: `set_current_site_image`, as permissões (GRANT/REVOKE) e o bucket
-- `site-images` com suas políticas, que ficam intactos como backup. Apagá-lo é
-- uma decisão à parte, depois de a migração dos arquivos se provar.
--
-- Para voltar atrás: recriar a função com a checagem em storage.objects (o
-- corpo está em 20261103094627_admin_e_imagens_do_site.sql).

create or replace function public.add_site_image_version(p_slot text, p_storage_path text, p_width int default null, p_height int default null)
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

comment on column public.site_image_version.storage_path is
  'Caminho relativo do arquivo (<slot>/<uuid>.webp), igual no bucket S3 e no endereço do CloudFront.';
