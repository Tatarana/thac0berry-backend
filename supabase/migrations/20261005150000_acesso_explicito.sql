-- Acesso explícito à Data API (2026-10-05).
-- O projeto na nuvem foi criado com "Automatically expose new tables"
-- DESLIGADO (recomendação do Supabase): nenhuma tabela fica acessível pela API
-- sem um GRANT escrito aqui. O ambiente local (CLI) libera tudo por padrão;
-- por isso esta migração primeiro REVOGA tudo, para o CI se comportar igual
-- à nuvem, e depois concede só o necessário. As regras de quem vê qual LINHA
-- continuam nas políticas RLS da migração da Fase 1.

-- Nada liberado por padrão, local ou nuvem.
revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke all on all functions in schema public from anon, authenticated;
alter default privileges in schema public revoke all on tables    from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
alter default privileges in schema public revoke all on functions from anon, authenticated;

-- Usuário logado: ler, criar e editar (sem DELETE: exclusão é marcação em
-- `deleted_at`). Anônimo: nada.
grant select, insert, update on
  public.user_preferences,
  public.campaign,
  public.session,
  public.character,
  public.spell_sheet,
  public.notebook_entry
to authenticated;

-- Anexos são imutáveis: só ler e registrar.
grant select, insert on public.attachment to authenticated;

-- Os valores padrão de change_seq chamam nextval() como o próprio usuário.
grant usage on sequence public.sync_change_seq to authenticated;

-- public.record_history: nenhum acesso pela API (nem leitura). A função do
-- trigger grava nele como dona (security definer).
