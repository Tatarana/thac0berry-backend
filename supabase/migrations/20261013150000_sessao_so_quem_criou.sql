-- Sessão: só quem criou, ou o mestre, edita, fecha (is_archived) e apaga
-- (deleted_at) — decisão do usuário, 2026-10-13, ao testar a Fase 2a: "ninguém
-- pode apagar ou fechar o que foi criado por outra pessoa". Os outros membros
-- continuam lendo todas e criando as suas (20261013120000_fase2a_membros_e_convites.sql).

drop policy "membro edita" on public.session;
create policy "autor ou mestre edita" on public.session for update to authenticated
  using (owner_id = (select auth.uid()) or public.is_campaign_gm(campaign_id))
  with check (public.is_campaign_member(campaign_id));
