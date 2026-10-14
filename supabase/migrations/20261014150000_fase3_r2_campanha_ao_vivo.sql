-- Fase 3, R2: página da campanha ao vivo (2026-10-14; docs/modelo-de-dados-e-sync.md §9).
--
-- Um jogador não lê a ficha completa dos outros, então não receberia pelo
-- Realtime a mudança dos PV de um colega. Em vez de assinar as tabelas, os
-- membros assinam o "pulso" da campanha: uma linha por campanha com a hora da
-- última mudança, que os gatilhos abaixo atualizam quando muda a campanha, uma
-- ficha (ao entrar, mudar ou sair), uma folha de magia, uma sessão, um membro
-- ou um acesso temporário. O aviso não leva dado nenhum; a página relê o que
-- mostra (elenco, grupo, sessões, jogadores) pelas consultas de sempre.

create table public.campaign_pulse (
  campaign_id uuid primary key references public.campaign on delete cascade,
  changed_at  timestamptz not null default now()
);

alter table public.campaign_pulse enable row level security;
create policy "membro lê" on public.campaign_pulse for select to authenticated
  using (public.is_campaign_member(campaign_id));
grant select on public.campaign_pulse to authenticated;

alter publication supabase_realtime add table public.campaign_pulse;

-- Marca a campanha (nula = nada a marcar).
create function public.pulse_campaign(p_campaign uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.campaign_pulse (campaign_id, changed_at)
  select p_campaign, now()
  where p_campaign is not null and exists (select 1 from public.campaign where id = p_campaign)
  on conflict (campaign_id) do update set changed_at = now();
$$;

revoke execute on function public.pulse_campaign(uuid) from public, anon, authenticated;

-- Gatilhos: a campanha da linha nova e, se mudou, a da antiga.
create function public.pulse_from_campaign_id()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- (sem tocar em `old` num INSERT nem em `new` num DELETE)
  if tg_op = 'INSERT' then
    perform public.pulse_campaign(new.campaign_id);
  elsif tg_op = 'UPDATE' then
    perform public.pulse_campaign(new.campaign_id);
    if old.campaign_id is distinct from new.campaign_id then
      perform public.pulse_campaign(old.campaign_id);
    end if;
  else
    perform public.pulse_campaign(old.campaign_id);
  end if;
  return null;
end;
$$;

create function public.pulse_from_campaign()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.pulse_campaign(new.id);
  return null;
end;
$$;

create function public.pulse_from_character_id()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.pulse_campaign((select c.campaign_id from public.character c where c.id = new.character_id));
  return null;
end;
$$;

create trigger campaign_pulse after update on public.campaign
  for each row execute function public.pulse_from_campaign();
create trigger campaign_pulse after insert or update on public.character
  for each row execute function public.pulse_from_campaign_id();
create trigger campaign_pulse after insert or update on public.session
  for each row execute function public.pulse_from_campaign_id();
create trigger campaign_pulse after insert or update or delete on public.campaign_member
  for each row execute function public.pulse_from_campaign_id();
create trigger campaign_pulse after insert or update on public.spell_sheet
  for each row execute function public.pulse_from_character_id();
create trigger campaign_pulse after insert or update on public.character_grant
  for each row execute function public.pulse_from_character_id();
